import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';
import { validateWorkflow } from './validate-release-workflow.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const validSource = fs.readFileSync(path.join(here, 'fixtures', 'valid-release-workflow.yml'), 'utf8');

function violations(source = validSource) {
  return validateWorkflow(parse(source));
}

function mutate(search, replacement) {
  assert.ok(validSource.includes(search), `fixture contains mutation target: ${search}`);
  return validSource.replace(search, replacement);
}

function rejects(name, search, replacement, expected) {
  test(name, () => {
    const errors = violations(mutate(search, replacement));
    assert.ok(errors.some((error) => error.includes(expected)), errors.join('\n'));
  });
}

function rejectsObjectMutation(name, change, expected) {
  test(name, () => {
    const workflow = parse(validSource);
    change(workflow);
    const errors = validateWorkflow(workflow);
    assert.ok(errors.some((error) => error.includes(expected)), errors.join('\n'));
  });
}

function stepById(workflow, jobName, id) {
  return workflow.jobs[jobName].steps.find((step) => step.id === id);
}

test('accepts the complete behavior-tested build-once graph', () => assert.deepEqual(violations(), []));

rejectsObjectMutation('rejects a result step without canonical output emission', (workflow) => {
  stepById(workflow, 'promote', 'result').run = 'echo result';
}, 'run scalar:');
rejects('rejects a decoy workflow output mapping',
  'value: ${{ jobs.promote.outputs.image-digest }}',
  'value: ${{ steps.result.outputs.image-digest }}', 'workflow output image-digest:');
rejects('rejects a detached second build action',
  'uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a',
  'uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a\n      - uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a',
  'build: exactly one');
rejectsObjectMutation('rejects the sole build action moved outside jobs.build.steps', (workflow) => {
  const index = workflow.jobs.build.steps.findIndex((step) => step.id === 'build');
  workflow.jobs.verify.steps.push(...workflow.jobs.build.steps.splice(index, 1));
}, 'build: the sole build action');
rejects('rejects an incomplete custom exporter',
  'outputs: type=image,name=${{ inputs.image }},push-by-digest=true,name-canonical=true,push=true',
  'outputs: type=image,push-by-digest=true,name-canonical=true', 'build: exporter');
rejects('rejects top-level build push',
  '          provenance: mode=max',
  '          push: true\n          provenance: mode=max', 'build: top-level');
rejects('rejects top-level build tags',
  '          provenance: mode=max',
  '          tags: image:mutable\n          provenance: mode=max', 'build: top-level');
rejects('rejects an indirect promote needs graph',
  '    needs:\n      - build\n      - verify',
  '    needs: verify', 'graph: promote');
rejects('rejects a job condition override',
  '  verify:\n    needs: build',
  '  verify:\n    needs: build\n    if: success()', 'bypass:');
rejects('rejects a load-bearing step condition override',
  '      - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25',
  '      - if: success()\n        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25',
  'bypass:');
rejects('rejects continue-on-error even when expression-shaped',
  '      - name: Export and validate attached attestations',
  '      - name: Export and validate attached attestations\n        continue-on-error: ${{ true }}', 'bypass:');
rejects('rejects a suffixed Trivy action ref',
  'aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25',
  'aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25/scan', 'Trivy: action ref');
rejectsObjectMutation('rejects the sole Trivy action moved outside verify', (workflow) => {
  const index = workflow.jobs.verify.steps.findIndex((step) => step.uses?.startsWith('aquasecurity/trivy-action@'));
  workflow.jobs.build.steps.push(...workflow.jobs.verify.steps.splice(index, 1));
}, 'Trivy: exactly one');
rejects('rejects a canonical Trivy reference with a tag suffix',
  'image-ref: ${{ env.IMAGE_REFERENCE }}',
  'image-ref: ${{ env.IMAGE_REFERENCE }}:latest', 'Trivy: canonical');
rejects('rejects a nonblocking Trivy exit code',
  'exit-code: "1"', 'exit-code: "0"', 'Trivy: fixable');
rejects('rejects a policy that includes unfixed findings contrary to the declared gate',
  'ignore-unfixed: true', 'ignore-unfixed: false', 'Trivy: fixable');
rejectsObjectMutation('rejects shell control flow wrapped around a canonical scalar', (workflow) => {
  const step = stepById(workflow, 'build', 'validate-inputs');
  step.run = `if true; then\n${step.run}\nfi`;
}, 'run scalar:');
rejectsObjectMutation('rejects extra shell appended to a canonical scalar', (workflow) => {
  stepById(workflow, 'promote', 'promote-image').run += '\necho bypass';
}, 'run scalar:');
test('rejects executable image-build CLI added to any run scalar', () => {
  for (const command of ['docker build .', 'docker buildx build .', 'docker compose build app', 'buildctl build']) {
    const workflow = parse(validSource);
    stepById(workflow, 'verify', 'verify-attestations').run += `\n${command}`;
    assert.ok(validateWorkflow(workflow).some((error) => error.includes('run scalar:')), command);
  }
});
test('rejects executable registry mutation CLI added to any run scalar', () => {
  for (const command of ['docker push image:tag', 'crane copy source target', 'oras copy source target']) {
    const workflow = parse(validSource);
    stepById(workflow, 'build', 'validate-inputs').run += `\n${command}`;
    assert.ok(validateWorkflow(workflow).some((error) => error.includes('run scalar:')), command);
  }
});
rejectsObjectMutation('rejects executable Trivy CLI outside the selected action', (workflow) => {
  stepById(workflow, 'build', 'validate-inputs').run += '\ntrivy image "$IMAGE"';
}, 'run scalar:');
rejectsObjectMutation('rejects executable raw docker login outside login actions', (workflow) => {
  stepById(workflow, 'build', 'validate-inputs').run += '\ndocker login registry.example.test';
}, 'run scalar:');
rejects('rejects broad build permissions',
  '      packages: write\n    outputs:',
  '      packages: write\n      id-token: write\n    outputs:', 'permissions: build');
rejectsObjectMutation('rejects contents access in the read-only verify job', (workflow) => {
  workflow.jobs.verify.permissions.contents = 'read';
}, 'permissions: verify');
rejectsObjectMutation('rejects contents access in the promote job', (workflow) => {
  workflow.jobs.promote.permissions.contents = 'read';
}, 'permissions: promote');
rejects('rejects duplicate checkout in the build job',
  '      - name: Validate release inputs',
  '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n        with:\n          persist-credentials: false\n      - name: Validate release inputs',
  'checkout: build');
rejectsObjectMutation('rejects a caller checkout in verify', (workflow) => {
  workflow.jobs.verify.steps.unshift({ uses: 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' });
}, 'checkout: verify');
rejects('rejects a credential-less registry login',
  '          password: ${{ secrets.registry-password }}\n',
  '', 'login: build');
rejects('rejects a write credential in the verify login',
  'password: ${{ secrets.registry-read-password }}',
  'password: ${{ secrets.registry-password }}', 'login: verify');
rejects('rejects a mutable Syft generator',
  'docker/buildkit-syft-scanner:1.11.0@sha256:79e7b013cbec16bbb436f312819a49a4a57752b2270c1a9332ae1a10fcc82a68',
  'docker/buildkit-syft-scanner:stable-1', 'Syft:');
rejectsObjectMutation('rejects a missing attestation behavior scalar', (workflow) => {
  workflow.jobs.verify.steps = workflow.jobs.verify.steps.filter((step) => step.id !== 'verify-attestations');
}, 'run scalar: verify-attestations');
rejects('rejects a wrong canonical verify environment',
  'IMAGE_REFERENCE: ${{ needs.build.outputs.image-reference }}',
  'IMAGE_REFERENCE: ${{ inputs.image }}:candidate', 'verify env:');
rejects('rejects uploading a decoy SBOM path',
  'path: sbom.spdx.json',
  'path: .', 'artifacts:');
rejectsObjectMutation('rejects the result step moved before promotion', (workflow) => {
  const steps = workflow.jobs.promote.steps;
  const index = steps.findIndex((step) => step.id === 'result');
  steps.unshift(...steps.splice(index, 1));
}, 'result:');
rejects('rejects a wrong SBOM artifact output environment',
  'SBOM_ARTIFACT: sbom-${{ github.sha }}',
  'SBOM_ARTIFACT: sbom-latest', 'result:');
rejects('rejects a validation image derived from the wrong input',
  'IMAGE: ${{ inputs.image }}\n          VERSION:',
  'IMAGE: ${{ github.repository }}\n          VERSION:', 'validation env:');
rejects('rejects missing canonical build labels',
  '            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}\n',
  '', 'build: labels');
rejects('rejects a missing read-only registry credential interface',
  '      registry-read-password:\n        required: true\n',
  '', 'secrets:');
rejectsObjectMutation('rejects a case-variant duplicate build action', (workflow) => {
  workflow.jobs.verify.steps.push({
    uses: 'Docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a'
  });
}, 'build: exactly one');
rejectsObjectMutation('rejects a case-variant duplicate Trivy action', (workflow) => {
  workflow.jobs.build.steps.push({
    uses: 'Aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25'
  });
}, 'Trivy: exactly one');
rejects('rejects removal of the reserved revision-tag version guard',
  '          [[ "$VERSION" != "sha-$GITHUB_SHA" ]]\n',
  '', 'run scalar:');
