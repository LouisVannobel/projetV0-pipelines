import fs from 'node:fs';
import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { parse } from 'yaml';

const refs = {
  build: 'docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a',
  checkout: 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
  login: 'docker/login-action@dbcb813823bdd20940b903addbd779551569679f',
  setup: 'docker/setup-buildx-action@37fe631027851001ddb9b187196cc803df7f5f0e',
  trivy: 'aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25',
  upload: 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
};
const buildkit = 'image=moby/buildkit:v0.32.2@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8';
const syft = 'docker/buildkit-syft-scanner:1.11.0@sha256:79e7b013cbec16bbb436f312819a49a4a57752b2270c1a9332ae1a10fcc82a68';
const exporter = 'type=image,name=${{ inputs.image }},push-by-digest=true,name-canonical=true,push=true';
const releaseOutputs = ['image-digest', 'image-reference', 'sbom-artifact'];
const canonicalRunJobs = {
  'validate-inputs': 'build',
  'verify-attestations': 'verify',
  'promote-image': 'promote',
  result: 'promote'
};

const hasOwn = (object, key) => Object.hasOwn(object ?? {}, key);
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const stepsOf = (job) => Array.isArray(job?.steps) ? job.steps : [];
const compact = (value) => typeof value === 'string' ? value.replace(/\s+/g, '') : '';
const sameKeys = (object, keys) => {
  if (!isObject(object) || Object.keys(object).length !== keys.length) return false;
  return keys.every((key) => Object.hasOwn(object, key));
};
const sameRecord = (object, expected) => sameKeys(object, Object.keys(expected))
  && Object.entries(expected).every(([key, value]) => object[key] === value);
const fail = (errors, condition, message) => { if (!condition) errors.push(message); };
const normalizeUse = (value) => typeof value === 'string' ? value.toLowerCase() : '';

function actionSteps(jobs, prefix) {
  const normalizedPrefix = `${prefix.toLowerCase()}@`;
  return Object.entries(jobs).flatMap(([jobName, job]) => stepsOf(job)
    .map((step, index) => ({ jobName, index, step }))
    .filter(({ step }) => normalizeUse(step?.uses).startsWith(normalizedPrefix)));
}

function runEntries(jobs) {
  return Object.entries(jobs).flatMap(([jobName, job]) => stepsOf(job)
    .map((step, index) => ({ jobName, index, step }))
    .filter(({ step }) => typeof step?.run === 'string'));
}

function runById(workflow, jobName, id) {
  return stepsOf(workflow?.jobs?.[jobName]).find((step) => step?.id === id);
}

const canonicalFixtureUrl = new URL('./fixtures/valid-release-workflow.yml', import.meta.url);
const productionWorkflowUrl = new URL('../../.github/workflows/reusable-oci-release.yml', import.meta.url);
const canonicalFixture = parse(fs.readFileSync(canonicalFixtureUrl, 'utf8'));
const canonicalRuns = Object.fromEntries(Object.entries(canonicalRunJobs).map(([id, jobName]) => {
  const run = runById(canonicalFixture, jobName, id)?.run;
  if (typeof run !== 'string') throw new Error(`canonical fixture is missing ${jobName}.${id}`);
  return [id, run];
}));

function validateGraph(workflow, jobs, build, verify, promote, errors) {
  fail(errors, sameKeys(jobs, ['build', 'verify', 'promote']),
    'graph: workflow needs exactly build, verify, and promote jobs');
  fail(errors, !hasOwn(build, 'needs'), 'graph: build must not need another job');
  fail(errors, verify.needs === 'build', 'graph: verify must need exactly build');
  fail(errors, Array.isArray(promote.needs) && promote.needs.length === 2
    && promote.needs[0] === 'build' && promote.needs[1] === 'verify',
  'graph: promote must directly need exactly build and verify');
  fail(errors, isObject(workflow?.permissions) && Object.keys(workflow.permissions).length === 0,
    'permissions: workflow root must remain empty');
}

function validateJobBoundaries(jobs, errors) {
  for (const [jobName, job] of Object.entries(jobs)) {
    fail(errors, !hasOwn(job, 'if') && !hasOwn(job, 'continue-on-error'),
      `bypass: ${jobName} job must not override if or continue-on-error`);
    for (const [index, step] of stepsOf(job).entries()) {
      fail(errors, !hasOwn(step, 'if') && !hasOwn(step, 'continue-on-error'),
      `bypass: ${jobName} step ${index + 1} must not override if or continue-on-error`);
    }
  }
}

function validateJobSetup(jobs, errors) {
  const expectedPermissions = {
    build: { contents: 'read', packages: 'write' },
    verify: { packages: 'read' },
    promote: { packages: 'write' }
  };
  const expectedLoginPassword = {
    build: '${{ secrets.registry-password }}',
    verify: '${{ secrets.registry-read-password }}',
    promote: '${{ secrets.registry-password }}'
  };
  for (const jobName of ['build', 'verify', 'promote']) {
    const job = jobs[jobName] ?? {};
    const jobSteps = stepsOf(job);
    fail(errors, sameRecord(job.permissions, expectedPermissions[jobName]),
      `permissions: ${jobName} must grant exactly ${JSON.stringify(expectedPermissions[jobName])}`);

    const checkouts = jobSteps.filter((step) => typeof step?.uses === 'string'
      && normalizeUse(step.uses).startsWith('actions/checkout@'));
    const checkoutValid = jobName === 'build'
      ? checkouts.length === 1 && normalizeUse(checkouts[0].uses) === refs.checkout
        && sameRecord(checkouts[0].with, { 'persist-credentials': false })
      : checkouts.length === 0;
    fail(errors, checkoutValid, `checkout: ${jobName} has the wrong caller-checkout boundary`);

    const setups = jobSteps.filter((step) => typeof step?.uses === 'string'
      && normalizeUse(step.uses).startsWith('docker/setup-buildx-action@'));
    fail(errors, setups.length === 1 && normalizeUse(setups[0].uses) === refs.setup && sameRecord(setups[0].with, {
      version: 'v0.36.1',
      'driver-opts': buildkit
    }), `Buildx: ${jobName} needs exactly one pinned setup`);

    const logins = jobSteps.filter((step) => typeof step?.uses === 'string'
      && normalizeUse(step.uses).startsWith('docker/login-action@'));
    fail(errors, logins.length === 1 && normalizeUse(logins[0].uses) === refs.login && sameRecord(logins[0].with, {
      registry: '${{ inputs.registry }}',
      username: '${{ inputs.registry-username }}',
      password: expectedLoginPassword[jobName]
    }), `login: ${jobName} needs exactly one pinned login with the scoped credential`);
  }
}

function validateInterface(workflow, promote, errors) {
  const workflowCall = workflow?.on?.workflow_call;
  const workflowOutputs = workflowCall?.outputs;
  fail(errors, workflowCall?.inputs?.platforms?.default === 'linux/amd64',
    'platform: workflow input must default to linux/amd64');
  fail(errors, sameKeys(workflowCall?.secrets, ['registry-password', 'registry-read-password'])
    && workflowCall.secrets['registry-password']?.required === true
    && workflowCall.secrets['registry-read-password']?.required === true,
  'secrets: write and read registry credentials must both be required');
  fail(errors, sameKeys(workflowOutputs, releaseOutputs),
    'workflow outputs: exactly the three release outputs are required');
  fail(errors, sameKeys(promote.outputs, releaseOutputs),
    'promote outputs: exactly the three result outputs are required');
  for (const name of releaseOutputs) {
    fail(errors, compact(workflowOutputs?.[name]?.value) === compact(`\${{ jobs.promote.outputs.${name} }}`),
      `workflow output ${name}: must map exactly jobs.promote.outputs.${name}`);
    fail(errors, compact(promote.outputs?.[name]) === compact(`\${{ steps.result.outputs.${name} }}`),
      `promote output ${name}: must map exactly steps.result.outputs.${name}`);
  }
}

function validateCanonicalRuns(jobs, errors) {
  const allRuns = runEntries(jobs);
  fail(errors, allRuns.length === Object.keys(canonicalRunJobs).length,
    'run scalar: exactly four canonical behavior scalars are required');
  for (const [id, jobName] of Object.entries(canonicalRunJobs)) {
    const matches = allRuns.filter(({ step }) => step.id === id);
    fail(errors, matches.length === 1 && matches[0].jobName === jobName
      && matches[0].step.shell === 'bash' && matches[0].step.run === canonicalRuns[id],
    `run scalar: ${id} must be the exact canonical scalar in jobs.${jobName}`);
  }
}

function validateBuild(workflow, jobs, build, errors) {
  const validation = runById(workflow, 'build', 'validate-inputs') ?? {};
  fail(errors, sameRecord(validation.env, {
    REGISTRY: '${{ inputs.registry }}',
    IMAGE: '${{ inputs.image }}',
    VERSION: '${{ inputs.version }}',
    PLATFORMS: '${{ inputs.platforms }}',
    GITHUB_SHA: '${{ github.sha }}'
  }), 'validation env: inputs must map through the exact quoted environment');

  const builds = actionSteps(jobs, 'docker/build-push-action');
  const buildEntry = builds[0] ?? {};
  const buildStep = buildEntry.step ?? {};
  const buildWith = buildStep.with ?? {};
  fail(errors, builds.length === 1, 'build: exactly one docker/build-push-action step is required');
  fail(errors, buildEntry.jobName === 'build', 'build: the sole build action must be in jobs.build.steps');
  fail(errors, normalizeUse(buildStep.uses) === refs.build && buildStep.id === 'build',
    'build: the sole build action must use the canonical pin and id');
  fail(errors, buildWith.outputs === exporter, 'build: exporter must be the exact canonical digest exporter');
  fail(errors, !hasOwn(buildWith, 'push') && !hasOwn(buildWith, 'tags'),
    'build: top-level push and tags are forbidden');
  fail(errors, buildWith.sbom === `generator=${syft}`,
    'Syft: the immutable generator must be bound through the build action SBOM input');
  fail(errors, sameKeys(buildWith, [
    'context', 'file', 'platforms', 'outputs', 'labels', 'provenance', 'sbom', 'cache-from', 'cache-to'
  ]) && buildWith.context === '${{ inputs.docker-context }}'
    && buildWith.file === '${{ inputs.dockerfile }}'
    && buildWith.platforms === '${{ inputs.platforms }}'
    && buildWith.provenance === 'mode=max'
    && buildWith.sbom === `generator=${syft}`
    && buildWith['cache-from'] === 'type=gha'
    && buildWith['cache-to'] === 'type=gha,mode=max',
  'build: canonical context, platform, provenance, SBOM, and cache inputs are required');
  fail(errors, String(buildWith.labels ?? '').trimEnd() === [
    'org.opencontainers.image.revision=${{ github.sha }}',
    'org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}'
  ].join('\n'), 'build: labels must bind the triggering revision and source');
  fail(errors, sameRecord(build.outputs, {
    'image-digest': '${{ steps.build.outputs.digest }}',
    'image-reference': '${{ inputs.image }}@${{ steps.build.outputs.digest }}'
  }), 'build outputs: canonical digest and reference must derive exactly from steps.build.outputs.digest');
  fail(errors, stepsOf(build).indexOf(validation) < stepsOf(build).indexOf(buildStep),
    'build: validation must run before the sole build');
}

function validateVerify(workflow, jobs, verify, errors) {
  fail(errors, sameRecord(verify.env, {
    IMAGE_REFERENCE: '${{ needs.build.outputs.image-reference }}'
  }), 'verify env: IMAGE_REFERENCE must derive exactly from needs.build.outputs.image-reference');
  const trivyActions = actionSteps(jobs, 'aquasecurity/trivy-action');
  const trivyEntry = trivyActions[0] ?? {};
  const trivyStep = trivyEntry.step ?? {};
  fail(errors, trivyActions.length === 1 && trivyEntry.jobName === 'verify',
    'Trivy: exactly one structurally parsed action must be in verify');
  fail(errors, normalizeUse(trivyStep.uses) === refs.trivy,
    'Trivy: action ref must be the exact canonical pin with no suffix');
  fail(errors, trivyStep.with?.['image-ref'] === '${{ env.IMAGE_REFERENCE }}',
    'Trivy: canonical env.IMAGE_REFERENCE with no suffix is required');
  fail(errors, sameRecord(trivyStep.with, {
    version: 'v0.74.0',
    'scan-type': 'image',
    'image-ref': '${{ env.IMAGE_REFERENCE }}',
    scanners: 'vuln,secret',
    severity: 'HIGH,CRITICAL',
    'ignore-unfixed': true,
    'exit-code': '1'
  }), 'Trivy: fixable HIGH/CRITICAL vuln,secret findings must block the canonical digest');

  const verifyBehavior = runById(workflow, 'verify', 'verify-attestations');
  fail(errors, stepsOf(verify).indexOf(verifyBehavior) > stepsOf(verify).indexOf(trivyStep),
    'attestations: canonical export and validation must run after Trivy');
  const uploads = actionSteps(jobs, 'actions/upload-artifact');
  const expectedArtifacts = {
    'sbom-${{ github.sha }}': 'sbom.spdx.json',
    'provenance-${{ github.sha }}': 'provenance.slsa.json'
  };
  fail(errors, uploads.length === 2 && uploads.every(({ jobName, step, index }) =>
    jobName === 'verify' && normalizeUse(step.uses) === refs.upload
      && index > stepsOf(verify).indexOf(verifyBehavior))
    && Object.entries(expectedArtifacts).every(([name, artifactPath]) => uploads.some(({ step }) =>
      sameRecord(step.with, { name, path: artifactPath, 'if-no-files-found': 'error' }))),
  'artifacts: verify must upload exactly the validated SPDX and SLSA predicate files');
}

function validatePromote(workflow, promote, errors) {
  fail(errors, sameRecord(promote.env, {
    IMAGE: '${{ inputs.image }}',
    DIGEST: '${{ needs.build.outputs.image-digest }}',
    VERSION: '${{ inputs.version }}',
    GITHUB_SHA: '${{ github.sha }}'
  }), 'promotion env: canonical image, build digest, version, and SHA mappings are required');
  const promotion = runById(workflow, 'promote', 'promote-image');
  const result = runById(workflow, 'promote', 'result');
  fail(errors, stepsOf(promote).indexOf(result) > stepsOf(promote).indexOf(promotion),
    'result: the output step must run after verified promotion');
  fail(errors, sameRecord(result?.env, { SBOM_ARTIFACT: 'sbom-${{ github.sha }}' }),
    'result: exact canonical SBOM artifact environment is required');
}

export function validateWorkflow(workflow) {
  const errors = [];
  const jobs = isObject(workflow?.jobs) ? workflow.jobs : {};
  const build = jobs.build ?? {};
  const verify = jobs.verify ?? {};
  const promote = jobs.promote ?? {};

  validateGraph(workflow, jobs, build, verify, promote, errors);
  validateJobBoundaries(jobs, errors);
  validateJobSetup(jobs, errors);
  validateInterface(workflow, promote, errors);
  validateCanonicalRuns(jobs, errors);
  validateBuild(workflow, jobs, build, errors);
  validateVerify(workflow, jobs, verify, errors);
  validatePromote(workflow, promote, errors);

  return errors;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 2) {
    console.error('validator: does not accept paths');
    process.exit(2);
  }
  try {
    const errors = validateWorkflow(parse(fs.readFileSync(productionWorkflowUrl, 'utf8')));
    if (errors.length) {
      console.error(errors.join('\n'));
      process.exitCode = 1;
    }
  } catch (error) {
    console.error(`validator: ${error.message}`);
    process.exitCode = 1;
  }
}
