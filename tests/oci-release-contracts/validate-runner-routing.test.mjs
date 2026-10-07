import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { parse } from 'yaml';
import { validateWorkflow as validateRelease } from './validate-release-workflow.mjs';

const defaultRunnerJson = '["ubuntu-24.04"]';
const isolatedLabels = ['self-hosted', 'linux', 'x64', 'sparra-isolated'];
const routingExpression = '${{fromJSON(inputs.runs-on)}}';
const definitions = [
  ['repository CI', 'reusable-repository-ci.yml', ['repository-security', 'infrastructure-static']],
  ['OCI release', 'reusable-oci-release.yml', ['build', 'verify', 'promote']]
];
const loadWorkflow = file => parse(fs.readFileSync(
  new URL(`../../.github/workflows/${file}`, import.meta.url), 'utf8'
));
const repositoryBaseline = parse(fs.readFileSync(
  new URL('./fixtures/repository-ci-before-runner-routing.yml', import.meta.url), 'utf8'
));

function assertRouting(workflow, jobNames) {
  const input = workflow.on?.workflow_call?.inputs?.['runs-on'];
  assert.ok(input, 'runner input must exist');
  assert.equal(input.type, 'string', 'runner input must accept JSON through a string');
  assert.notEqual(input.required, true, 'existing callers must not require a new runner input');
  assert.equal(input.default, defaultRunnerJson, 'runner default must preserve ubuntu-24.04');
  assert.deepEqual(Object.keys(workflow.jobs), jobNames, 'required job set must stay unchanged');
  for (const name of jobNames) {
    assert.equal(typeof workflow.jobs[name]['runs-on'], 'string', `${name} needs one routing expression`);
    assert.equal(workflow.jobs[name]['runs-on'].replace(/\s+/g, ''), routingExpression,
      `${name} must route from the caller runner input`);
  }
}

function assertRepositoryControls(workflow) {
  const restored = structuredClone(workflow);
  delete restored.on.workflow_call.inputs['runs-on'];
  for (const job of Object.values(restored.jobs)) job['runs-on'] = 'ubuntu-24.04';
  assert.deepEqual(restored, repositoryBaseline,
    'runner selection must not change repository permissions, conditions, scans or scripts');
}

for (const [name, file, jobs] of definitions) {
  test(`${name}: all required jobs consume optional caller runner routing`, () => {
    assertRouting(loadWorkflow(file), jobs);
  });

  test(`${name}: omitted routing preserves the hosted Linux default`, () => {
    const workflow = loadWorkflow(file);
    assertRouting(workflow, jobs);
    assert.deepEqual(JSON.parse(workflow.on.workflow_call.inputs['runs-on'].default), ['ubuntu-24.04']);
  });

  test(`${name}: isolated Linux labels use the same input for every job`, () => {
    const workflow = loadWorkflow(file);
    assertRouting(workflow, jobs);
    // The exact fromJSON binding is checked above; this is its caller value,
    // not a replacement evaluator for GitHub Actions expressions.
    const callerInput = JSON.stringify(isolatedLabels);
    assert.deepEqual(JSON.parse(callerInput), isolatedLabels);
  });

  test(`${name}: routing contract rejects absent, required and changed-default inputs`, () => {
    const workflow = loadWorkflow(file);
    assertRouting(workflow, jobs);
    const mutations = [
      changed => { delete changed.on.workflow_call.inputs['runs-on']; },
      changed => { changed.on.workflow_call.inputs['runs-on'].type = 'boolean'; },
      changed => { changed.on.workflow_call.inputs['runs-on'].required = true; },
      changed => { changed.on.workflow_call.inputs['runs-on'].default = 'ubuntu-24.04'; },
      changed => { changed.on.workflow_call.inputs['runs-on'].default = '["self-hosted"]'; }
    ];
    for (const mutate of mutations) {
      const changed = structuredClone(workflow);
      mutate(changed);
      assert.throws(() => assertRouting(changed, jobs), assert.AssertionError);
    }
  });

  test(`${name}: a single unrouted required job cannot pass the contract`, () => {
    const workflow = loadWorkflow(file);
    assertRouting(workflow, jobs);
    for (const job of jobs) {
      for (const value of ['ubuntu-24.04', '${{ inputs.runs-on }}', '${{ fromJSON(inputs.platforms) }}']) {
        const changed = structuredClone(workflow);
        changed.jobs[job]['runs-on'] = value;
        assert.throws(() => assertRouting(changed, jobs), assert.AssertionError, `${job}: ${value}`);
      }
    }
  });
}

test('repository routing preserves every existing security and optional infrastructure control', () => {
  const workflow = loadWorkflow('reusable-repository-ci.yml');
  assertRepositoryControls(workflow);
  const weakened = structuredClone(workflow);
  weakened.jobs['repository-security'].steps.at(-1).with['exit-code'] = '0';
  assert.throws(() => assertRepositoryControls(weakened), assert.AssertionError);
});

test('OCI routing preserves the existing build-once, permission and digest gates', () => {
  assert.deepEqual(validateRelease(loadWorkflow('reusable-oci-release.yml')), []);
});
