import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { loadYaml, validateExample, validateSmokeWorkflow } from './validate-smoke-workflow.mjs';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const repository = path.resolve(testDir, '..', '..');
const smokePath = path.join(repository, '.github', 'workflows', 'smoke-oci-release.yml');
const examplePath = path.join(repository, 'examples', 'oci-release.yml');

test('the repository smoke caller proves the additive OCI release contract', () => {
  assert.equal(fs.existsSync(smokePath), true, 'smoke workflow must exist');
  assert.deepEqual(validateSmokeWorkflow(loadYaml(smokePath)), []);
});

test('the separate OCI example exposes metadata but deploys only the digest reference', () => {
  assert.equal(fs.existsSync(examplePath), true, 'OCI example must exist');
  assert.deepEqual(validateExample(loadYaml(examplePath)), []);
});
