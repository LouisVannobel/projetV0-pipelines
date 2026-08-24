import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const harnesses = [
  'test-release-run-blocks.mjs',
  'test-smoke-run-block.mjs'
];

test('shell harnesses use fixed Bash and never execute writable PATH fakes', () => {
  for (const harness of harnesses) {
    const source = fs.readFileSync(path.join(here, harness), 'utf8');
    assert.equal(source.includes('fs.chmodSync'), false, `${harness} uses runtime JavaScript chmod`);
    assert.equal(source.includes('fakeBin'), false, `${harness} creates a writable fake-bin boundary`);
    assert.equal(source.includes('PATH="$root/'), false, `${harness} prepends a writable directory to PATH`);
    assert.equal(source.includes("spawnSync('bash'"), false, `${harness} resolves Bash through PATH`);
    assert.equal(source.split('spawnSync(').length - 1, 1, `${harness} has one process boundary`);
    assert.ok(source.includes('spawnSync(bashExecutable'), `${harness} invokes fixed Bash directly`);
    assert.ok(source.includes("process.platform === 'win32'"), `${harness} selects fixed Bash by platform`);
    assert.ok(source.includes("'C:/Program Files/Git/bin/bash.exe'"), `${harness} fixes Git Bash on Windows`);
    assert.ok(source.includes("'/usr/bin/bash'"), `${harness} fixes Bash on non-Windows runners`);
    assert.ok(source.includes('export -f'), `${harness} exports controlled shell fakes`);
  }
});
