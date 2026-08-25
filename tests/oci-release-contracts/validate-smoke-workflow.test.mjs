import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';
import { validateExample, validateSmokeWorkflow } from './validate-smoke-workflow.mjs';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const repository = path.resolve(testDir, '..', '..');
const smokePath = path.join(repository, '.github', 'workflows', 'smoke-oci-release.yml');
const examplePath = path.join(repository, 'examples', 'oci-release.yml');
const fixtureDockerfilePath = path.join(repository, 'tests', 'fixtures', 'oci-release', 'Dockerfile');
const validatorPath = path.join(testDir, 'validate-smoke-workflow.mjs');
const loadFixture = (file) => parse(fs.readFileSync(file, 'utf8'));

test('the repository smoke caller proves the additive OCI release contract', () => {
  assert.equal(fs.existsSync(smokePath), true, 'smoke workflow must exist');
  assert.deepEqual(validateSmokeWorkflow(loadFixture(smokePath)), []);
});

test('the permanent smoke caller has no branch push trigger', () => {
  const triggers = loadFixture(smokePath).on;
  assert.deepEqual(Object.keys(triggers), ['workflow_dispatch']);
  assert.equal(Object.hasOwn(triggers, 'push'), false);
});

test('the exact scratch smoke fixture ends with a numeric non-root identity', () => {
  assert.equal(fs.readFileSync(fixtureDockerfilePath, 'utf8').replaceAll('\r\n', '\n'), [
    'FROM scratch',
    '',
    'COPY payload.txt /payload.txt',
    'USER 65532:65532',
    ''
  ].join('\n'));
  const release = loadFixture(smokePath).jobs.release;
  assert.equal(release.with['docker-context'], 'tests/fixtures/oci-release');
  assert.equal(release.with.dockerfile, 'tests/fixtures/oci-release/Dockerfile');
});

test('smoke validator CLI reads only its fixed repository files', () => {
  const known = spawnSync(process.execPath, [validatorPath], { encoding: 'utf8' });
  assert.equal(known.status, 0, known.stderr);

  const redirected = spawnSync(process.execPath, [validatorPath, smokePath, examplePath], { encoding: 'utf8' });
  assert.equal(redirected.status, 2);
  assert.match(redirected.stderr, /does not accept paths/);
});

test('the separate OCI example exposes metadata but deploys only the digest reference', () => {
  assert.equal(fs.existsSync(examplePath), true, 'OCI example must exist');
  assert.deepEqual(validateExample(loadFixture(examplePath)), []);
});

test('the OCI example accepts only the serialized immutable workflow revision', () => {
  const example = loadFixture(examplePath);
  const corrected = structuredClone(example);
  corrected.jobs.release.uses = 'LouisVannobel/projetV0-pipelines/.github/workflows/reusable-oci-release.yml@97cf6d2c5348f202c232fd872c4d4592d430297b';
  assert.deepEqual(validateExample(corrected), []);

  const broken = structuredClone(example);
  broken.jobs.release.uses = 'LouisVannobel/projetV0-pipelines/.github/workflows/reusable-oci-release.yml@eff9cfbb1c66ed36a386f475d493ccf9daaed3c8';
  assert.match(validateExample(broken).join('\n'), /serialized immutable workflow SHA/);
});
