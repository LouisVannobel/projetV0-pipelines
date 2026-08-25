import fs from 'node:fs';
import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { parse } from 'yaml';

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const sameKeys = (object, keys) => {
  if (!isObject(object) || Object.keys(object).length !== keys.length) return false;
  return keys.every((key) => Object.hasOwn(object, key));
};
const stepsOf = (job) => Array.isArray(job?.steps) ? job.steps : [];
const fail = (errors, condition, message) => { if (!condition) errors.push(message); };
const smokeWorkflowUrl = new URL('../../.github/workflows/smoke-oci-release.yml', import.meta.url);
const exampleWorkflowUrl = new URL('../../examples/oci-release.yml', import.meta.url);

export function validateSmokeWorkflow(workflow) {
  const errors = [];
  const triggers = workflow?.on;
  const jobs = isObject(workflow?.jobs) ? workflow.jobs : {};
  const release = jobs.release ?? {};
  const evidence = jobs.evidence ?? {};
  const evidenceSteps = stepsOf(evidence);
  const login = evidenceSteps.filter((step) => typeof step?.uses === 'string'
    && step.uses.startsWith('docker/login-action@'));
  const inspect = evidenceSteps.find((step) => step?.id === 'inspect-raw-oci');
  const upload = evidenceSteps.filter((step) => typeof step?.uses === 'string'
    && step.uses.startsWith('actions/upload-artifact@'));

  fail(errors, sameKeys(triggers, ['workflow_dispatch']),
    'trigger: only workflow_dispatch is allowed');
  fail(errors, sameKeys(workflow?.permissions, []), 'permissions: workflow root must be empty');
  fail(errors, isObject(workflow?.concurrency)
    && workflow.concurrency.group === 'projetv0-pipelines-oci-smoke'
    && workflow.concurrency['cancel-in-progress'] === false
    && Object.keys(workflow.concurrency).length === 2,
  'concurrency: fixed smoke package must be serialized without cancellation');
  fail(errors, sameKeys(jobs, ['release', 'evidence']),
    'graph: smoke must contain exactly release and evidence jobs');

  fail(errors, release.uses === './.github/workflows/reusable-oci-release.yml',
    'release: must call the local reusable workflow from the same commit');
  fail(errors, isObject(release.permissions)
    && release.permissions.contents === 'read'
    && release.permissions.packages === 'write'
    && Object.keys(release.permissions).length === 2,
  'release: permissions must be contents read and packages write');
  fail(errors, release?.with?.image === 'ghcr.io/louisvannobel/projetv0-pipelines-smoke',
    'release: disposable image must be exact');
  fail(errors, release?.with?.platforms === 'linux/amd64',
    'release: smoke platform must be linux/amd64');
  fail(errors, release?.with?.['docker-context'] === 'tests/fixtures/oci-release'
    && release?.with?.dockerfile === 'tests/fixtures/oci-release/Dockerfile',
  'release: must build the isolated fixture');
  fail(errors, release?.with?.version === 'smoke-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}',
    'release: version must be non-reserved, commit-derived, and unique per attempt');
  fail(errors, release?.with?.['registry-username'] === '${{ github.actor }}',
    'release: registry identity must be the triggering actor');
  fail(errors, sameKeys(release?.secrets, ['registry-password', 'registry-read-password'])
    && release.secrets['registry-password'] === '${{ secrets.GITHUB_TOKEN }}'
    && release.secrets['registry-read-password'] === '${{ secrets.GITHUB_TOKEN }}',
  'release: both explicit reusable secrets must use the scoped GitHub token');

  fail(errors, evidence.needs === 'release', 'evidence: must need release');
  fail(errors, isObject(evidence.permissions)
    && evidence.permissions.packages === 'read'
    && Object.keys(evidence.permissions).length === 1,
  'evidence: permissions must be packages read only');
  fail(errors, evidence?.env?.IMAGE_DIGEST === '${{ needs.release.outputs.image-digest }}'
    && evidence?.env?.IMAGE_REFERENCE === '${{ needs.release.outputs.image-reference }}'
    && evidence?.env?.SBOM_ARTIFACT === '${{ needs.release.outputs.sbom-artifact }}',
  'evidence: must consume all reusable outputs');
  fail(errors, login.length === 1
    && login[0].uses === 'docker/login-action@dbcb813823bdd20940b903addbd779551569679f'
    && login[0]?.with?.registry === 'ghcr.io'
    && login[0]?.with?.username === '${{ github.actor }}'
    && login[0]?.with?.password === '${{ secrets.GITHUB_TOKEN }}',
  'evidence: must perform one fresh pinned GHCR login');
  fail(errors, typeof inspect?.run === 'string', 'evidence: raw OCI inspection step is required');
  if (typeof inspect?.run === 'string') {
    const run = inspect.run;
    for (const [needle, message] of [
      ['CRANE_VERSION=0.21.9', 'pin crane 0.21.9'],
      ['5c16d8ddb971cb1d5e6ed8b1e743da8224414eeba2c2762d8f1a61b2f095699e', 'verify the crane archive checksum'],
      ['crane manifest "$IMAGE_REFERENCE"', 'read the raw root index'],
      ['crane blob', 'read raw in-toto blobs'],
      ['application/vnd.docker.attestation.manifest.v1+json', 'validate the attestation artifact type'],
      ['application/vnd.in-toto+json', 'validate every statement layer media type'],
      ['https://in-toto.io/Statement/v1', 'require the current in-toto statement envelope'],
      ['https://spdx.dev/Document', 'require exactly one SPDX statement'],
      ['https://slsa.dev/provenance/v1', 'require exactly one SLSA v1 statement'],
      ['not builder_id.strip()', 'reject empty SLSA builder identities'],
      ['manifest_subject', 'validate the attestation manifest subject'],
      ['subject_digest', 'compare exact in-toto subjects'],
      ['crane digest "$IMAGE:$VERSION"', 'resolve the version tag'],
      ['crane digest "$IMAGE:sha-$GITHUB_SHA"', 'resolve the revision tag'],
      ['oci-evidence.json', 'write sanitized evidence']
    ]) fail(errors, run.includes(needle), `evidence: must ${message}`);
    fail(errors, !run.includes('https://in-toto.io/Statement/v0.1'),
      'evidence: obsolete in-toto v0.1 statement envelopes must be rejected');
  }
  fail(errors, upload.length === 1
    && upload[0].uses === 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
    && upload[0]?.with?.path === 'oci-evidence.json'
    && upload[0]?.with?.['if-no-files-found'] === 'error',
  'evidence: must upload exactly the sanitized OCI evidence file');

  return errors;
}

export function validateExample(workflow) {
  const errors = [];
  const jobs = isObject(workflow?.jobs) ? workflow.jobs : {};
  const release = jobs.release ?? {};
  const consume = jobs.consume ?? {};
  const uses = release.uses ?? '';
  const reviewedSha = '97cf6d2c5348f202c232fd872c4d4592d430297b';
  fail(errors, typeof uses === 'string'
    && uses === `LouisVannobel/projetV0-pipelines/.github/workflows/reusable-oci-release.yml@${reviewedSha}`,
  'example: reusable workflow must use the serialized immutable workflow SHA');
  fail(errors, consume.needs === 'release', 'example: consumer must need release');
  fail(errors, consume?.env?.IMAGE_DIGEST === '${{ needs.release.outputs.image-digest }}'
    && consume?.env?.IMAGE_REFERENCE === '${{ needs.release.outputs.image-reference }}'
    && consume?.env?.SBOM_ARTIFACT === '${{ needs.release.outputs.sbom-artifact }}',
  'example: consumer must expose all three reusable outputs');
  const deploy = stepsOf(consume).find((step) => step?.id === 'deploy-immutable-reference');
  fail(errors, typeof deploy?.run === 'string'
    && deploy.run.includes('"$IMAGE_REFERENCE"')
    && !deploy.run.includes('$IMAGE_DIGEST')
    && !deploy.run.includes('$SBOM_ARTIFACT'),
  'example: deployment must consume only image-reference');
  return errors;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 2) {
    console.error('validator: does not accept paths');
    process.exit(2);
  }
  const errors = [
    ...validateSmokeWorkflow(parse(fs.readFileSync(smokeWorkflowUrl, 'utf8'))),
    ...validateExample(parse(fs.readFileSync(exampleWorkflowUrl, 'utf8')))
  ];
  if (errors.length) {
    errors.forEach((error) => console.error(`- ${error}`));
    process.exit(1);
  }
  console.log('OCI_SMOKE_CONTRACT_OK');
}
