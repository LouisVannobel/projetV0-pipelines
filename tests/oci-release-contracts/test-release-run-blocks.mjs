import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test, { after } from 'node:test';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const workflowPath = path.join(root, '.github', 'workflows', 'reusable-oci-release.yml');
const workflow = parse(fs.readFileSync(workflowPath, 'utf8'));
const temporary = fs.mkdtempSync(path.join(root, '.tmp-release-run-blocks-'));
const scriptsDirectory = path.join(temporary, 'scalars');
const fakeBin = path.join(temporary, 'bin');
fs.mkdirSync(scriptsDirectory);
fs.mkdirSync(fakeBin);
after(() => fs.rmSync(temporary, { recursive: true, force: true }));

const expectedRuns = {
  'validate-inputs': 'build',
  'verify-attestations': 'verify',
  'promote-image': 'promote',
  result: 'promote'
};
const scriptPaths = {};
for (const [id, expectedJob] of Object.entries(expectedRuns)) {
  const matches = Object.entries(workflow.jobs ?? {}).flatMap(([jobName, job]) =>
    (job.steps ?? []).filter((step) => step.id === id && typeof step.run === 'string')
      .map((step) => ({ jobName, step })));
  assert.equal(matches.length, 1, `one ${id} run scalar exists`);
  assert.equal(matches[0].jobName, expectedJob, `${id} belongs to jobs.${expectedJob}`);
  scriptPaths[id] = path.join(scriptsDirectory, `${id}.sh`);
  fs.writeFileSync(scriptPaths[id], matches[0].step.run);
}

const relative = (target) => path.relative(root, target).replaceAll('\\', '/');
const runner = path.join(temporary, 'run-scalar.sh');
fs.writeFileSync(runner, `#!/usr/bin/env bash
set -Eeuo pipefail
root="$(pwd -P)"
source "$root/$1"
cd "$2"
chmod +x "$root/$3/docker"
PATH="$root/$3:$PATH"
export PATH
if [[ -n "\${DOCKER_LOG_REL:-}" ]]; then export DOCKER_LOG="$root/$DOCKER_LOG_REL"; fi
if [[ -n "\${PROMOTION_STATE_REL:-}" ]]; then export PROMOTION_STATE="$root/$PROMOTION_STATE_REL"; fi
if [[ -n "\${ROOT_FIXTURE_REL:-}" ]]; then export ROOT_FIXTURE="$root/$ROOT_FIXTURE_REL"; fi
if [[ -n "\${SBOM_FIXTURE_REL:-}" ]]; then export SBOM_FIXTURE="$root/$SBOM_FIXTURE_REL"; fi
if [[ -n "\${PROVENANCE_FIXTURE_REL:-}" ]]; then export PROVENANCE_FIXTURE="$root/$PROVENANCE_FIXTURE_REL"; fi
if [[ -n "\${GITHUB_OUTPUT_REL:-}" ]]; then export GITHUB_OUTPUT="$root/$GITHUB_OUTPUT_REL"; fi
bash "$root/$4"
`);
function execute(id, environment = {}, workingDirectory = root) {
  const environmentFile = path.join(temporary, `environment-${randomUUID()}.sh`);
  const shellQuote = (value) => `'${String(value).replaceAll("'", "'\\''")}'`;
  fs.writeFileSync(environmentFile, Object.entries(environment)
    .map(([name, value]) => `export ${name}=${shellQuote(value)}`)
    .join('\n'));
  return spawnSync('bash', [
    relative(runner), relative(environmentFile), relative(workingDirectory), relative(fakeBin), relative(scriptPaths[id])
  ], {
    cwd: root,
    encoding: 'utf8'
  });
}

const digest = `sha256:${'b'.repeat(64)}`;
const otherDigest = `sha256:${'c'.repeat(64)}`;
const platformDigest = `sha256:${'1'.repeat(64)}`;
const attestationDigest = `sha256:${'2'.repeat(64)}`;
const githubSha = 'a'.repeat(40);
const image = 'ghcr.io/acme/voice-cell';
const version = 'v1.2.3';

fs.writeFileSync(path.join(fakeBin, 'docker'), `#!/usr/bin/env bash
set -Eeuo pipefail
{
  printf '%s' "$1"
  printf '\\t%s' "\${@:2}"
  printf '\\n'
} >>"$DOCKER_LOG"

[[ "\${1:-}" == buildx && "\${2:-}" == imagetools ]] || exit 97
case "\${3:-}" in
  inspect)
    reference="\${4:-}"
    format="\${6:-}"
    if [[ "\${5:-}" == --raw ]]; then
      cat "$ROOT_FIXTURE"
    elif [[ "$format" == '{{ json .SBOM.SPDX }}' ]]; then
      cat "$SBOM_FIXTURE"
    elif [[ "$format" == '{{ json .Provenance.SLSA }}' ]]; then
      cat "$PROVENANCE_FIXTURE"
    elif [[ "$format" == '{{ .Manifest.Digest }}' ]]; then
      if [[ -f "$PROMOTION_STATE" ]]; then
        if [[ "$reference" == "$IMAGE:$VERSION" ]]; then
          printf '%s\\n' "\${FINAL_VERSION_DIGEST:-$DIGEST}"
        else
          printf '%s\\n' "\${FINAL_SHA_DIGEST:-$DIGEST}"
        fi
      elif [[ "$reference" == "$IMAGE:$VERSION" ]]; then
        mode="\${VERSION_EXISTING:-absent}"
        case "$mode" in
          same) printf '%s\\n' "$DIGEST" ;;
          different) printf '%s\\n' "$OTHER_DIGEST" ;;
          exact-absent) printf 'ERROR: %s: not found\\n' "$reference" >&2; exit 1 ;;
          manifest-absent) printf 'ERROR: %s: manifest unknown\\n' "$reference" >&2; exit 1 ;;
          name-absent) printf 'ERROR: %s: name unknown\\n' "$reference" >&2; exit 1 ;;
          auth) printf 'unauthorized: authentication required: not found\\n' >&2; exit 1 ;;
          network) printf 'connection refused while resolving: not found\\n' >&2; exit 1 ;;
          tls) printf 'tls: failed to verify certificate: not found\\n' >&2; exit 1 ;;
          timeout) printf 'request timeout: not found\\n' >&2; exit 1 ;;
          server) printf 'server returned 503 Service Unavailable: not found\\n' >&2; exit 1 ;;
          malformed-not-found) printf 'parser error: unexpected not found token\\n' >&2; exit 1 ;;
          credential-helper-not-found) printf 'exec: docker-credential-ghcr: executable file not found in PATH\\n' >&2; exit 1 ;;
          unrelated-not-found) printf 'ERROR: ghcr.io/other/image:tag: not found\\n' >&2; exit 1 ;;
          mixed-multiline) printf 'ERROR: %s: not found\\nparser warning: ignored token\\n' "$reference" >&2; exit 1 ;;
          *) exit 96 ;;
        esac
      elif [[ "$reference" == "$IMAGE:sha-$GITHUB_SHA" ]]; then
        mode="\${SHA_EXISTING:-absent}"
        case "$mode" in
          same) printf '%s\\n' "$DIGEST" ;;
          different) printf '%s\\n' "$OTHER_DIGEST" ;;
          exact-absent) printf 'ERROR: %s: not found\\n' "$reference" >&2; exit 1 ;;
          manifest-absent) printf 'ERROR: %s: manifest unknown\\n' "$reference" >&2; exit 1 ;;
          name-absent) printf 'ERROR: %s: name unknown\\n' "$reference" >&2; exit 1 ;;
          auth) printf 'unauthorized: authentication required: not found\\n' >&2; exit 1 ;;
          network) printf 'connection refused while resolving: not found\\n' >&2; exit 1 ;;
          tls) printf 'tls: failed to verify certificate: not found\\n' >&2; exit 1 ;;
          timeout) printf 'request timeout: not found\\n' >&2; exit 1 ;;
          server) printf 'server returned 503 Service Unavailable: not found\\n' >&2; exit 1 ;;
          malformed-not-found) printf 'parser error: unexpected not found token\\n' >&2; exit 1 ;;
          credential-helper-not-found) printf 'exec: docker-credential-ghcr: executable file not found in PATH\\n' >&2; exit 1 ;;
          unrelated-not-found) printf 'ERROR: ghcr.io/other/image:tag: not found\\n' >&2; exit 1 ;;
          mixed-multiline) printf 'ERROR: %s: not found\\nparser warning: ignored token\\n' "$reference" >&2; exit 1 ;;
          *) exit 96 ;;
        esac
      else
        exit 95
      fi
    else
      exit 94
    fi
    ;;
  create) touch "$PROMOTION_STATE" ;;
  *) exit 93 ;;
esac
`);

const fixtures = path.join(temporary, 'fixtures');
fs.mkdirSync(fixtures);
const fixture = (name, value) => {
  const target = path.join(fixtures, name);
  fs.writeFileSync(target, `${JSON.stringify(value)}\n`);
  return target;
};
const runnable = {
  mediaType: 'application/vnd.oci.image.manifest.v1+json',
  digest: platformDigest,
  platform: { os: 'linux', architecture: 'amd64' }
};
const attestation = {
  mediaType: 'application/vnd.oci.image.manifest.v1+json',
  digest: attestationDigest,
  platform: { os: 'unknown', architecture: 'unknown' },
  annotations: {
    'vnd.docker.reference.type': 'attestation-manifest',
    'vnd.docker.reference.digest': platformDigest
  }
};
const rootValid = fixture('root-valid.json', {
  schemaVersion: 2,
  mediaType: 'application/vnd.oci.image.index.v1+json',
  manifests: [runnable, attestation]
});
const rootMissingAttestation = fixture('root-missing-attestation.json', {
  schemaVersion: 2,
  mediaType: 'application/vnd.oci.image.index.v1+json',
  manifests: [runnable]
});
const rootWrongPlatform = fixture('root-wrong-platform.json', {
  schemaVersion: 2,
  mediaType: 'application/vnd.oci.image.index.v1+json',
  manifests: [{ ...runnable, platform: { os: 'linux', architecture: 'arm64' } }, attestation]
});
const rootExtraRunnable = fixture('root-extra-runnable.json', {
  schemaVersion: 2,
  mediaType: 'application/vnd.oci.image.index.v1+json',
  manifests: [runnable, {
    ...runnable,
    digest: `sha256:${'3'.repeat(64)}`,
    platform: { os: 'linux', architecture: 'arm64' }
  }, attestation]
});
const sbomValid = fixture('sbom-valid.json', {
  SPDXID: 'SPDXRef-DOCUMENT', spdxVersion: 'SPDX-2.3', packages: [{ name: 'voice-cell' }]
});
const sbomWrong = fixture('sbom-wrong.json', { SPDXID: 'not-a-document', spdxVersion: 'SPDX-2.3' });
const provenanceValid = fixture('provenance-valid.json', {
  buildDefinition: {
    buildType: 'https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md'
  },
  runDetails: { builder: { id: 'https://github.com/moby/buildkit' } }
});
const provenanceObsoleteBuildType = fixture('provenance-obsolete-build-type.json', {
  buildDefinition: { buildType: 'https://mobyproject.org/buildkit@v1' },
  runDetails: { builder: { id: 'https://github.com/moby/buildkit' } }
});
const provenanceEmptyBuilder = fixture('provenance-empty-builder.json', {
  buildDefinition: {
    buildType: 'https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md'
  },
  runDetails: { builder: { id: '' } }
});
const provenanceWhitespaceBuilder = fixture('provenance-whitespace-builder.json', {
  buildDefinition: {
    buildType: 'https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md'
  },
  runDetails: { builder: { id: '   ' } }
});
const provenanceWrong = fixture('provenance-wrong.json', {
  buildDefinition: {}, runDetails: { builder: {} }
});

const validInputEnvironment = {
  REGISTRY: 'ghcr.io', IMAGE: image, VERSION: version, PLATFORMS: 'linux/amd64', GITHUB_SHA: githubSha
};

test('release input scalar validates the supported immutable namespace', () => {
  assert.equal(execute('validate-inputs', validInputEnvironment).status, 0);
  for (const override of [
    { PLATFORMS: 'linux/arm64' },
    { VERSION: 'bad tag' },
    { VERSION: 'LATEST' },
    { VERSION: `sha-${githubSha}` },
    { IMAGE: `${image}:mutable` },
    { IMAGE: 'registry.example.test/acme/voice-cell' }
  ]) {
    assert.notEqual(execute('validate-inputs', { ...validInputEnvironment, ...override }).status, 0,
      JSON.stringify(override));
  }
});

function verifyEnvironment(rootFixture = rootValid, sbomFixture = sbomValid, provenanceFixture = provenanceValid) {
  return {
    IMAGE_REFERENCE: `${image}@${digest}`,
    DOCKER_LOG_REL: relative(path.join(temporary, 'verify-docker.log')),
    PROMOTION_STATE_REL: relative(path.join(temporary, 'verify-promoted')),
    ROOT_FIXTURE_REL: relative(rootFixture),
    SBOM_FIXTURE_REL: relative(sbomFixture),
    PROVENANCE_FIXTURE_REL: relative(provenanceFixture),
    DIGEST: digest,
    IMAGE: image,
    VERSION: version,
    GITHUB_SHA: githubSha
  };
}

test('attestation scalar exports and validates the root, SPDX, and SLSA predicates', () => {
  const validDirectory = fs.mkdtempSync(path.join(temporary, 'verify-valid-'));
  const valid = execute('verify-attestations', verifyEnvironment(), validDirectory);
  assert.equal(valid.status, 0, valid.stderr);
  for (const artifact of ['root-index.json', 'sbom.spdx.json', 'provenance.slsa.json']) {
    assert.ok(fs.statSync(path.join(validDirectory, artifact)).size > 0, artifact);
  }
  for (const [name, environment] of [
    ['missing descriptor', verifyEnvironment(rootMissingAttestation)],
    ['wrong platform', verifyEnvironment(rootWrongPlatform)],
    ['extra runnable', verifyEnvironment(rootExtraRunnable)],
    ['wrong SPDX', verifyEnvironment(rootValid, sbomWrong)],
    ['obsolete BuildKit build type', verifyEnvironment(rootValid, sbomValid, provenanceObsoleteBuildType)],
    ['empty builder identity', verifyEnvironment(rootValid, sbomValid, provenanceEmptyBuilder)],
    ['whitespace builder identity', verifyEnvironment(rootValid, sbomValid, provenanceWhitespaceBuilder)],
    ['wrong SLSA', verifyEnvironment(rootValid, sbomValid, provenanceWrong)]
  ]) {
    const caseDirectory = fs.mkdtempSync(path.join(temporary, 'verify-invalid-'));
    assert.notEqual(execute('verify-attestations', environment, caseDirectory).status, 0, name);
  }
});

function promotionCase(versionExisting, shaExisting, extra = {}) {
  const caseDirectory = fs.mkdtempSync(path.join(temporary, 'promotion-'));
  const log = path.join(caseDirectory, 'docker.log');
  const state = path.join(caseDirectory, 'promoted');
  fs.writeFileSync(log, '');
  const environment = {
    IMAGE: image,
    DIGEST: digest,
    OTHER_DIGEST: otherDigest,
    VERSION: version,
    GITHUB_SHA: githubSha,
    VERSION_EXISTING: versionExisting,
    SHA_EXISTING: shaExisting,
    DOCKER_LOG_REL: relative(log),
    PROMOTION_STATE_REL: relative(state),
    ...extra
  };
  const result = execute('promote-image', environment);
  return { result, log: fs.readFileSync(log, 'utf8') };
}

const createLines = (log) => log.split(/\r?\n/).filter((line) => line.startsWith('buildx\timagetools\tcreate\t'));

const promotionDiagnostics = [
  ['exact-absent', true],
  ['manifest-absent', true],
  ['name-absent', true],
  ['same', true],
  ['different', false],
  ['auth', false],
  ['network', false],
  ['tls', false],
  ['timeout', false],
  ['server', false],
  ['malformed-not-found', false],
  ['credential-helper-not-found', false],
  ['unrelated-not-found', false],
  ['mixed-multiline', false]
];

for (const destination of ['version', 'revision']) {
  for (const [mode, accepted] of promotionDiagnostics) {
    test(`promotion ${accepted ? 'accepts' : 'rejects'} ${destination} diagnostic ${mode}`, () => {
      const versionExisting = destination === 'version' ? mode : 'same';
      const shaExisting = destination === 'revision' ? mode : 'same';
      const { result, log } = promotionCase(versionExisting, shaExisting);
      assert.equal(result.status === 0, accepted, result.stderr);
      assert.equal(createLines(log).length, accepted ? 1 : 0);
    });
  }
}

test('promotion fails when a destination appears after an accepted absence probe', () => {
  const raced = promotionCase('exact-absent', 'exact-absent', { FINAL_VERSION_DIGEST: otherDigest });
  assert.notEqual(raced.result.status, 0);
  assert.equal(createLines(raced.log).length, 1);
});

test('promotion rejects a version that aliases the revision destination', () => {
  const { result, log } = promotionCase('exact-absent', 'exact-absent', { VERSION: `sha-${githubSha}` });
  assert.notEqual(result.status, 0);
  assert.equal(log, '');
});

test('result scalar validates the digest and writes exactly three outputs', () => {
  const output = path.join(temporary, 'github-output');
  fs.writeFileSync(output, '');
  const valid = execute('result', {
    IMAGE: image,
    DIGEST: digest,
    SBOM_ARTIFACT: `sbom-${githubSha}`,
    GITHUB_OUTPUT_REL: relative(output)
  });
  assert.equal(valid.status, 0, valid.stderr);
  assert.equal(fs.readFileSync(output, 'utf8'), [
    `image-digest=${digest}`,
    `image-reference=${image}@${digest}`,
    `sbom-artifact=sbom-${githubSha}`,
    ''
  ].join('\n'));

  fs.writeFileSync(output, '');
  const invalid = execute('result', {
    IMAGE: image,
    DIGEST: 'sha256:bad',
    SBOM_ARTIFACT: `sbom-${githubSha}`,
    GITHUB_OUTPUT_REL: relative(output)
  });
  assert.notEqual(invalid.status, 0);
  assert.equal(fs.readFileSync(output, 'utf8'), '');
});

test('result scalar emits all outputs through one grouped append', () => {
  const run = fs.readFileSync(scriptPaths.result, 'utf8');
  assert.equal((run.match(/>>\s*"\$GITHUB_OUTPUT"/g) ?? []).length, 1);
  assert.match(run, /\{[\s\S]*printf 'image-digest=%s\\n'[\s\S]*printf 'image-reference=%s@%s\\n'[\s\S]*printf 'sbom-artifact=%s\\n'[\s\S]*\}\s*>>\s*"\$GITHUB_OUTPUT"/);
});
