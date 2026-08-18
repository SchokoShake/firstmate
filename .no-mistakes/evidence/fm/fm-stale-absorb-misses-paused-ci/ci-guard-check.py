# Parse .github/workflows/ci.yml into a semantic model, pull the real count-guard
# script out of the "Stock macOS Bash snapshot compatibility" job, and run the
# guard's own assertions against the real test scripts' real output.
import re, subprocess, sys, yaml
wf = yaml.safe_load(open('.github/workflows/ci.yml'))
job = None
for name, j in wf['jobs'].items():
    if 'macos' in str(j.get('runs-on', '')) and 'snapshot' in str(j.get('name', '')).lower():
        job = (name, j)
if job is None:
    sys.exit('could not find the stock-macOS snapshot compatibility job')
name, j = job
step = [s for s in j['steps'] if 'run' in s][0]
script = step['run']
print(f'workflow job: {name}  ({j["name"]})')
print(f'step: {step["name"]}   shell: {step.get("shell")}   runs-on: {j["runs-on"]}')
print()
guards = re.findall(
    r'(\w+)_output=\$\(/bin/bash (tests/\S+)\)(?:.|\n)*?'
    r'\1_count=\$\(printf \'%s\\n\' "\$\1_output" \| grep -c \'\^ok - \'\)\s*'
    r'\[ "\$\1_count" -eq (\d+) \]', script)
if not guards:
    sys.exit('could not extract any count guard from the step script')
rc = 0
for label, test, expected in guards:
    out = subprocess.run(['/bin/bash', test], capture_output=True, text=True)
    actual = sum(1 for line in out.stdout.splitlines() if line.startswith('ok - '))
    notok = [l for l in (out.stdout + out.stderr).splitlines() if l.startswith('not ok')]
    verdict = 'PASS' if actual == int(expected) and out.returncode == 0 and not notok else 'FAIL'
    if verdict == 'FAIL':
        rc = 1
    print(f'{verdict}  {label}_count guard: {test}')
    print(f'        workflow expects -eq {expected}; script exit {out.returncode}; real "ok - " lines: {actual}'
          + (f'; failures: {notok}' if notok else ''))
sys.exit(rc)
