import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const harnessNames = [
  'test-release-run-blocks.mjs',
  'test-smoke-run-block.mjs'
];
const harnessSources = Object.fromEntries(harnessNames.map((name) => [
  name,
  fs.readFileSync(path.join(here, name), 'utf8').replace(/\r\n/g, '\n')
]));

const fixedBashSelection = [
  "const bashExecutable = process.platform === 'win32'",
  "  ? 'C:/Program Files/Git/bin/bash.exe'",
  "  : '/usr/bin/bash';"
].join('\n');
const fixedPythonSelection = [
  "const pythonExecutable = process.platform === 'win32'",
  '  ? process.env.OCI_TEST_PYTHON3',
  "  : '/usr/bin/python3';"
].join('\n');

export function validateHarnessSource(name, source) {
  for (const forbidden of ['fakeBin', 'fs.chmodSync', 'os.homedir', 'codex-runtimes', 'path.delimiter']) {
    assert.equal(source.includes(forbidden), false, `${name} contains forbidden ${forbidden}`);
  }

  for (const [lineNumber, line] of source.split(/\r?\n/).entries()) {
    const location = `${name}:${lineNumber + 1}`;
    assert.doesNotMatch(line, /\.\s*PATH\b/, `${location} accesses a PATH property`);
    assert.doesNotMatch(line, /\[\s*['"]PATH['"]\s*\]/, `${location} accesses bracket PATH`);
    assert.doesNotMatch(line, /^\s*(?:const|let|var)\s+PATH\s*=/, `${location} assigns local PATH`);
    assert.doesNotMatch(line, /^\s*(?:export\s+)?PATH\s*=/, `${location} assigns shell PATH`);
    assert.doesNotMatch(line, /[{,]\s*PATH\s*:/, `${location} defines a PATH property`);
    assert.doesNotMatch(line, /\$(?:PATH\b|\{PATH\})/, `${location} expands shell PATH`);
  }

  assert.ok(source.includes(fixedBashSelection), `${name} selects fixed Bash executables`);
  assert.equal(source.split('spawnSync(').length - 1, 1, `${name} has one process boundary`);
  assert.ok(source.includes('spawnSync(bashExecutable, ['), `${name} invokes fixed Bash directly`);
  assert.ok(source.includes(fixedPythonSelection), `${name} selects explicit Python executables`);
  assert.ok(source.includes('path.isAbsolute(pythonExecutable)'), `${name} validates Windows Python is absolute`);
  assert.ok(source.includes('fs.existsSync(pythonExecutable)'), `${name} validates Python exists`);
  assert.ok(source.indexOf('const pythonExecutable') < source.indexOf('fs.mkdtempSync'),
    `${name} validates its runtime before creating temporary state`);

  const platformArgument = name === 'test-release-run-blocks.mjs' ? '$6' : '$5';
  const branchStart = source.indexOf(`if [[ "${platformArgument}" == win32 ]]; then`);
  const branchEnd = source.indexOf('\nfi\nexport -f', branchStart);
  assert.notEqual(branchStart, -1, `${name} has a Windows Python runner branch`);
  assert.notEqual(branchEnd, -1, `${name} closes its Python runner branch before exports`);
  const [windowsBranch, linuxBranch] = source.slice(branchStart, branchEnd).split('\nelse\n');
  assert.ok(windowsBranch?.includes("/usr/bin/tr -d '\\\\r'"), `${name} normalizes CR on Windows`);
  assert.ok(linuxBranch?.includes('python3() { /usr/bin/python3 "$@"; }'), `${name} calls fixed Linux Python`);
  assert.equal(linuxBranch?.includes('/usr/bin/tr'), false, `${name} never normalizes Linux Python output`);

  const expectedExport = name === 'test-release-run-blocks.mjs'
    ? 'export -f docker python3'
    : 'export -f curl sha256sum tar python3';
  assert.ok(source.includes(expectedExport), `${name} exports the exact controlled fake set`);
  if (name === 'test-smoke-run-block.mjs') {
    assert.ok(source.includes('/usr/bin/install -m 0700 "$CRANE_TEMPLATE" "$destination/crane"'),
      `${name} installs crane with private executable mode`);
  }
}

test('shell harness sources satisfy the complete command boundary contract', () => {
  for (const [name, source] of Object.entries(harnessSources)) {
    validateHarnessSource(name, source);
  }
});

test('security validator rejects alternate writable PATH and runtime mutations', () => {
  const release = harnessSources['test-release-run-blocks.mjs'];
  const smoke = harnessSources['test-smoke-run-block.mjs'];
  const mutations = [
    ['process.env.PATH', release.replace('const expectedRuns', 'process.env.PATH = "fake";\nconst expectedRuns')],
    ['bracket PATH', release.replace('const expectedRuns', 'env["PATH"] = "fake";\nconst expectedRuns')],
    ['object PATH', release.replace('const expectedRuns', 'const alternate = { PATH: "fake" };\nconst expectedRuns')],
    ['PATH-resolved Bash', release.replace('spawnSync(bashExecutable, [', "spawnSync('bash', [")],
    ['Codex Python', release.replace("  ? process.env.OCI_TEST_PYTHON3", "  ? 'C:/tmp/codex-runtimes/python.exe'")],
    ['missing docker export', release.replace('export -f docker python3', 'export -f python3')],
    ['public crane mode', smoke.replace('/usr/bin/install -m 0700', '/usr/bin/install -m 0755')],
    ['Linux CR stripping', smoke.replace(
      'python3() { /usr/bin/python3 "$@"; }',
      "python3() { /usr/bin/python3 \"$@\" | /usr/bin/tr -d '\\\\r'; }")]
  ];

  for (const [label, mutation] of mutations) {
    const isSmoke = label === 'public crane mode' || label === 'Linux CR stripping';
    const original = isSmoke ? smoke : release;
    assert.notEqual(mutation, original, `${label} mutation changes the source`);
    assert.throws(() => validateHarnessSource(
      isSmoke ? 'test-smoke-run-block.mjs' : 'test-release-run-blocks.mjs',
      mutation
    ), undefined, label);
  }
});

test('canonical PowerShell entrypoint owns and restores Windows Python discovery', () => {
  const source = fs.readFileSync(path.join(root, 'tests', 'test_oci_release_contracts.ps1'), 'utf8');
  for (const required of [
    "& py -3 -c 'import sys; print(sys.executable)'",
    'Resolve-Path -LiteralPath $pythonProbe',
    "[Environment]::SetEnvironmentVariable('OCI_TEST_PYTHON3'",
    'finally {',
    '$previousPython'
  ]) {
    assert.ok(source.includes(required), `PowerShell Python lifecycle includes ${required}`);
  }
});
