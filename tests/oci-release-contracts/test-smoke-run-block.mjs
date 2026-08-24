import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test, { after } from 'node:test';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const workflowPath = path.join(root, '.github', 'workflows', 'smoke-oci-release.yml');
const workflow = parse(fs.readFileSync(workflowPath, 'utf8'));
const inspectSteps = (workflow.jobs?.evidence?.steps ?? [])
  .filter((step) => step.id === 'inspect-raw-oci' && typeof step.run === 'string');
assert.equal(inspectSteps.length, 1, 'one production inspect-raw-oci scalar exists');
const productionRun = inspectSteps[0].run;

const temporary = fs.mkdtempSync(path.join(root, '.tmp-smoke-run-block-'));
const fakeBin = path.join(temporary, 'bin');
const fixturesDir = path.join(temporary, 'fixtures');
fs.mkdirSync(fakeBin);
fs.mkdirSync(fixturesDir);
after(() => fs.rmSync(temporary, { recursive: true, force: true }));

const relative = (target) => path.relative(root, target).replaceAll('\\', '/');
const sha256 = (value) => `sha256:${createHash('sha256').update(value).digest('hex')}`;
const writeRaw = (directory, name, value) => {
  const raw = typeof value === 'string' ? value : JSON.stringify(value);
  const target = path.join(directory, name);
  fs.writeFileSync(target, raw);
  return { target, raw, digest: sha256(raw), size: Buffer.byteLength(raw) };
};
const shellQuote = (value) => `'${String(value).replaceAll("'", "'\\''")}'`;

const image = 'ghcr.io/louisvannobel/projetv0-pipelines-smoke';
const githubSha = 'a'.repeat(40);
const runId = '32771332254';
const runAttempt = '1';
const version = `smoke-${githubSha}-${runId}-${runAttempt}`;
const configDigest = `sha256:${'c'.repeat(64)}`;
const layerDigest = `sha256:${'d'.repeat(64)}`;

function createFixtures(name, options = {}) {
  const directory = path.join(fixturesDir, `${name}-${randomUUID()}`);
  fs.mkdirSync(directory);
  const platformValue = options.platformRaw ?? {
    schemaVersion: 2,
    mediaType: 'application/vnd.oci.image.manifest.v1+json',
    config: options.config ?? {
      mediaType: 'application/vnd.oci.image.config.v1+json',
      digest: configDigest,
      size: 2
    },
    layers: options.layers ?? [{
      mediaType: 'application/vnd.oci.image.layer.v1.tar+gzip',
      digest: layerDigest,
      size: 4
    }]
  };
  const platform = writeRaw(directory, 'platform-manifest.json', platformValue);
  const subjectDigest = options.statementSubjectDigest ?? platform.digest.slice('sha256:'.length);
  const statementType = options.statementType ?? 'https://in-toto.io/Statement/v1';
  const sbom = writeRaw(directory, 'sbom-statement.json', {
    _type: statementType,
    predicateType: 'https://spdx.dev/Document',
    subject: [{ name: 'pkg:docker/smoke', digest: { sha256: subjectDigest } }],
    predicate: { SPDXID: 'SPDXRef-DOCUMENT', spdxVersion: 'SPDX-2.3' }
  });
  const provenance = writeRaw(directory, 'provenance-statement.json', {
    _type: statementType,
    predicateType: 'https://slsa.dev/provenance/v1',
    subject: [{ name: 'pkg:docker/smoke', digest: { sha256: subjectDigest } }],
    predicate: {
      buildDefinition: {
        buildType: options.buildType
          ?? 'https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md'
      },
      runDetails: { builder: { id: options.builderId ?? 'https://github.com/example/actions/runs/1' } }
    }
  });
  const attestation = writeRaw(directory, 'attestation-manifest.json', {
    schemaVersion: 2,
    mediaType: 'application/vnd.oci.image.manifest.v1+json',
    artifactType: options.artifactType ?? 'application/vnd.docker.attestation.manifest.v1+json',
    config: {
      mediaType: 'application/vnd.oci.empty.v1+json',
      digest: `sha256:${'e'.repeat(64)}`,
      size: 2
    },
    layers: [
      {
        mediaType: 'application/vnd.in-toto+json',
        digest: sbom.digest,
        size: sbom.size,
        annotations: { 'in-toto.io/predicate-type': 'https://spdx.dev/Document' }
      },
      {
        mediaType: 'application/vnd.in-toto+json',
        digest: provenance.digest,
        size: provenance.size,
        annotations: { 'in-toto.io/predicate-type': 'https://slsa.dev/provenance/v1' }
      }
    ],
    subject: {
      mediaType: 'application/vnd.oci.image.manifest.v1+json',
      digest: options.attestationSubjectDigest ?? platform.digest,
      size: platform.size
    }
  });
  const descriptorPlatformDigest = options.descriptorPlatformDigest ?? platform.digest;
  const linkedDigest = options.linkedDigest ?? descriptorPlatformDigest;
  const rootIndex = writeRaw(directory, 'root-index.json', {
    schemaVersion: 2,
    mediaType: 'application/vnd.oci.image.index.v1+json',
    manifests: [
      {
        mediaType: 'application/vnd.oci.image.manifest.v1+json',
        digest: descriptorPlatformDigest,
        size: platform.size,
        platform: { architecture: 'amd64', os: 'linux' }
      },
      {
        mediaType: 'application/vnd.oci.image.manifest.v1+json',
        digest: attestation.digest,
        size: attestation.size,
        annotations: {
          'vnd.docker.reference.digest': linkedDigest,
          'vnd.docker.reference.type': 'attestation-manifest'
        },
        platform: { architecture: 'unknown', os: 'unknown' }
      }
    ]
  });
  return { directory, rootIndex, platform, attestation, sbom, provenance };
}

fs.writeFileSync(path.join(fakeBin, 'curl'), `#!/usr/bin/env bash
set -Eeuo pipefail
printf 'curl\\n' >>"$COMMAND_LOG"
output=''
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == --output ]]; then output="$2"; shift 2; else shift; fi
done
[[ -n "$output" ]]
printf 'archive' >"$output"
`);
fs.writeFileSync(path.join(fakeBin, 'sha256sum'), `#!/usr/bin/env bash
set -Eeuo pipefail
line="$(cat)"
printf 'sha256sum\\t%s\\n' "$line" >>"$COMMAND_LOG"
expected="\${line%%  *}"
file="\${line#*  }"
if [[ "$expected" == 5c16d8ddb971cb1d5e6ed8b1e743da8224414eeba2c2762d8f1a61b2f095699e ]]; then
  [[ "$file" == "$RUNNER_TEMP/go-containerregistry_Linux_x86_64.tar.gz" ]]
  touch "$CHECKSUM_MARKER"
else
  /usr/bin/sha256sum --check <<<"$line"
fi
`);
fs.writeFileSync(path.join(fakeBin, 'tar'), `#!/usr/bin/env bash
set -Eeuo pipefail
printf 'tar\\n' >>"$COMMAND_LOG"
[[ -f "$CHECKSUM_MARKER" ]]
destination=''
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == -C ]]; then destination="$2"; shift 2; else shift; fi
done
[[ -n "$destination" ]]
cp "$CRANE_TEMPLATE" "$destination/crane"
chmod +x "$destination/crane"
`);
const craneTemplate = path.join(fakeBin, 'crane-template');
fs.writeFileSync(craneTemplate, `#!/usr/bin/env bash
set -Eeuo pipefail
{
  printf 'crane'
  printf '\\t%s' "$@"
  printf '\\n'
} >>"$COMMAND_LOG"
command="\${1:-}"
reference="\${2:-}"
case "$command" in
  digest)
    if [[ "$reference" == "$IMAGE_REFERENCE" ]]; then
      printf '%s\\n' "$IMAGE_DIGEST"
    elif [[ "$reference" == "$IMAGE:$VERSION" || "$reference" == "$IMAGE:sha-$GITHUB_SHA" ]]; then
      printf '%s\\n' "\${TAG_DIGEST_OVERRIDE:-$IMAGE_DIGEST}"
    else
      exit 91
    fi
    ;;
  manifest)
    if [[ "$reference" == "$IMAGE_REFERENCE" ]]; then
      cat "$ROOT_FIXTURE"
    elif [[ "$reference" == "$IMAGE@$PLATFORM_DIGEST" ]]; then
      [[ "\${PLATFORM_MODE:-present}" != missing ]]
      cat "$PLATFORM_FIXTURE"
    elif [[ "$reference" == "$IMAGE@$ATTESTATION_DIGEST" ]]; then
      cat "$ATTESTATION_FIXTURE"
    else
      exit 92
    fi
    ;;
  blob)
    if [[ "$reference" == "$IMAGE@$SBOM_DIGEST" ]]; then
      cat "$SBOM_FIXTURE"
    elif [[ "$reference" == "$IMAGE@$PROVENANCE_DIGEST" ]]; then
      cat "$PROVENANCE_FIXTURE"
    else
      exit 93
    fi
    ;;
  *) exit 94 ;;
esac
`);
for (const file of ['curl', 'sha256sum', 'tar', 'crane-template']) {
  fs.chmodSync(path.join(fakeBin, file), 0o755);
}

const runner = path.join(temporary, 'run-smoke-scalar.sh');
fs.writeFileSync(runner, `#!/usr/bin/env bash
set -Eeuo pipefail
root="$(pwd -P)"
source "$root/$1"
export PATH="$root/$2:$PATH"
export RUNNER_TEMP="$root/$RUNNER_TEMP_REL"
export COMMAND_LOG="$root/$COMMAND_LOG_REL"
export CHECKSUM_MARKER="$root/$CHECKSUM_MARKER_REL"
export CRANE_TEMPLATE="$root/$CRANE_TEMPLATE_REL"
export ROOT_FIXTURE="$root/$ROOT_FIXTURE_REL"
export PLATFORM_FIXTURE="$root/$PLATFORM_FIXTURE_REL"
export ATTESTATION_FIXTURE="$root/$ATTESTATION_FIXTURE_REL"
export SBOM_FIXTURE="$root/$SBOM_FIXTURE_REL"
export PROVENANCE_FIXTURE="$root/$PROVENANCE_FIXTURE_REL"
cd "$root/$WORKING_DIRECTORY_REL"
bash "$root/$3"
`);

function execute(fixtures, overrides = {}, runScalar = productionRun) {
  const caseDirectory = path.join(temporary, `case-${randomUUID()}`);
  const runnerTemp = path.join(caseDirectory, 'runner-temp');
  fs.mkdirSync(caseDirectory);
  fs.mkdirSync(runnerTemp);
  const commandLog = path.join(caseDirectory, 'commands.log');
  fs.writeFileSync(commandLog, '');
  const scalarPath = path.join(caseDirectory, 'inspect-raw-oci.sh');
  fs.writeFileSync(scalarPath, runScalar);
  const environmentPath = path.join(caseDirectory, 'environment.sh');
  const environment = {
    IMAGE: image,
    GITHUB_SHA: githubSha,
    GITHUB_RUN_ID: runId,
    GITHUB_RUN_ATTEMPT: runAttempt,
    IMAGE_DIGEST: fixtures.rootIndex.digest,
    IMAGE_REFERENCE: `${image}@${fixtures.rootIndex.digest}`,
    SBOM_ARTIFACT: `sbom-${githubSha}`,
    VERSION: version,
    PLATFORM_DIGEST: fixtures.platform.digest,
    ATTESTATION_DIGEST: fixtures.attestation.digest,
    SBOM_DIGEST: fixtures.sbom.digest,
    PROVENANCE_DIGEST: fixtures.provenance.digest,
    RUNNER_TEMP_REL: relative(runnerTemp),
    COMMAND_LOG_REL: relative(commandLog),
    CHECKSUM_MARKER_REL: relative(path.join(caseDirectory, 'checksum-ok')),
    CRANE_TEMPLATE_REL: relative(craneTemplate),
    ROOT_FIXTURE_REL: relative(fixtures.rootIndex.target),
    PLATFORM_FIXTURE_REL: relative(overrides.platformFixture ?? fixtures.platform.target),
    ATTESTATION_FIXTURE_REL: relative(overrides.attestationFixture ?? fixtures.attestation.target),
    SBOM_FIXTURE_REL: relative(fixtures.sbom.target),
    PROVENANCE_FIXTURE_REL: relative(fixtures.provenance.target),
    WORKING_DIRECTORY_REL: relative(caseDirectory),
    PLATFORM_MODE: overrides.platformMode ?? 'present',
    TAG_DIGEST_OVERRIDE: overrides.tagDigestOverride ?? '',
  };
  fs.writeFileSync(environmentPath, Object.entries(environment)
    .map(([name, value]) => `export ${name}=${shellQuote(value)}`)
    .join('\n'));
  const result = spawnSync('bash', [
    relative(runner), relative(environmentPath), relative(fakeBin), relative(scalarPath)
  ], { cwd: root, encoding: 'utf8' });
  return {
    ...result,
    caseDirectory,
    commandLog: fs.readFileSync(commandLog, 'utf8'),
    evidencePath: path.join(caseDirectory, 'oci-evidence.json')
  };
}

test('live-shaped raw OCI graph succeeds and emits sanitized evidence', () => {
  const fixtures = createFixtures('valid');
  const result = execute(fixtures);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.commandLog, /crane\tmanifest\tghcr\.io\/louisvannobel\/projetv0-pipelines-smoke@sha256:/);
  assert.match(result.commandLog, new RegExp(`crane\\tmanifest\\t${image}@${fixtures.platform.digest}`));
  assert.match(result.commandLog, new RegExp(`crane\\tmanifest\\t${image}@${fixtures.attestation.digest}`));
  assert.match(result.commandLog, /crane\tblob\t.*\ncrane\tblob\t/);
  assert.match(result.commandLog, /sha256sum\t5c16d8ddb971cb1d5e6ed8b1e743da8224414eeba2c2762d8f1a61b2f095699e/);
  assert.equal(fs.existsSync(result.evidencePath), true);
  const evidence = JSON.parse(fs.readFileSync(result.evidencePath, 'utf8'));
  assert.deepEqual(Object.keys(evidence).sort(), [
    'attestation_digest', 'commit', 'image_reference', 'platform_digest', 'revision_tag_digest',
    'root_digest', 'run_attempt', 'run_id', 'version_tag_digest'
  ]);
  assert.equal(JSON.stringify(evidence).includes('password'), false);
});

test('obsolete envelopes, build type, and missing builder identities fail', () => {
  for (const [name, fixtures] of [
    ['obsolete build type', createFixtures('obsolete-build-type', { buildType: 'https://mobyproject.org/buildkit@v1' })],
    ['Statement v0.1', createFixtures('statement-v0', { statementType: 'https://in-toto.io/Statement/v0.1' })],
    ['empty builder', createFixtures('empty-builder', { builderId: '' })],
    ['whitespace builder', createFixtures('whitespace-builder', { builderId: '   ' })]
  ]) {
    const result = execute(fixtures);
    assert.notEqual(result.status, 0, `${name} unexpectedly passed`);
  }
});

test('missing, malformed, digest-mismatched, and structurally invalid runnable children fail', () => {
  const valid = createFixtures('child-valid');
  assert.notEqual(execute(valid, { platformMode: 'missing' }).status, 0, 'missing child');

  const malformed = createFixtures('child-malformed', { platformRaw: '{not-json' });
  assert.notEqual(execute(malformed).status, 0, 'malformed child');

  const alternate = createFixtures('child-alternate', {
    layers: [{ mediaType: 'application/vnd.oci.image.layer.v1.tar+zstd', digest: layerDigest, size: 5 }]
  });
  assert.notEqual(execute(valid, { platformFixture: alternate.platform.target }).status, 0, 'digest mismatch');

  const emptyLayers = createFixtures('child-empty-layers', { layers: [] });
  assert.notEqual(execute(emptyLayers).status, 0, 'empty layers');

  const badConfig = createFixtures('child-bad-config', {
    config: { mediaType: 'application/vnd.oci.image.config.v1+json', digest: 'sha256:bad', size: 2 }
  });
  assert.notEqual(execute(badConfig).status, 0, 'bad config descriptor');
});

test('digest-mismatched or malformed attestation and statement subject mismatch fail', () => {
  const valid = createFixtures('attestation-valid');
  const alternate = writeRaw(valid.directory, 'attestation-alternate.json', {
    ...JSON.parse(valid.attestation.raw),
    annotations: { 'example.test/changed-bytes': 'true' }
  });
  assert.notEqual(execute(valid, { attestationFixture: alternate.target }).status, 0,
    'attestation manifest digest mismatch');
  const wrongLink = createFixtures('wrong-link', { linkedDigest: `sha256:${'9'.repeat(64)}` });
  assert.notEqual(execute(wrongLink).status, 0, 'wrong root linkage');
  const wrongType = createFixtures('wrong-artifact-type', { artifactType: 'application/example' });
  assert.notEqual(execute(wrongType).status, 0, 'wrong attestation artifact type');
  const wrongManifestSubject = createFixtures('wrong-attestation-subject', {
    attestationSubjectDigest: `sha256:${'6'.repeat(64)}`
  });
  assert.notEqual(execute(wrongManifestSubject).status, 0, 'wrong attestation manifest subject');
  const wrongSubject = createFixtures('wrong-statement-subject', {
    statementSubjectDigest: '8'.repeat(64)
  });
  assert.notEqual(execute(wrongSubject).status, 0, 'wrong statement subject');
});

test('tag and root digest mismatch fails', () => {
  const fixtures = createFixtures('wrong-tag');
  const result = execute(fixtures, { tagDigestOverride: `sha256:${'7'.repeat(64)}` });
  assert.notEqual(result.status, 0);
});

test('commenting out the crane checksum cannot remain green', () => {
  const checksumLine = `printf '%s  %s\\n' "$CRANE_CHECKSUM" "$RUNNER_TEMP/$archive" | sha256sum --check`;
  const bypassed = productionRun.replace(checksumLine, '# checksum proof removed');
  assert.notEqual(bypassed, productionRun, 'production checksum proof must remain executable');
  const result = execute(createFixtures('checksum-bypass'), {}, bypassed);
  assert.notEqual(result.status, 0);
});
