# Releasing `openhost`

Everything needed to ship to PyPI, now and for every future release.

## One-time setup

### 1. Pick a name and reserve it on PyPI

The package is declared as `openhost` in `pyproject.toml`. Before the first
publish, go to <https://pypi.org/project/openhost/> and confirm the name is
available. If it isn't, pick another (`openhost-sdk`, `openhost-py`,
`openhost-local`, etc.) and update:

- `pyproject.toml` → `name = "..."`
- `CHANGELOG.md` references
- `README.md` install instructions

### 2. Create PyPI + TestPyPI accounts

- <https://pypi.org/account/register/> — production
- <https://test.pypi.org/account/register/> — dry-run index

Enable 2FA on both. Do not generate legacy API tokens — we use **trusted
publishing (OIDC)** instead, which is safer and has no secrets to rotate.

### 3. Push the repo to GitHub

```bash
cd ~/OpenHost
git init
git add .
git commit -m "initial commit"
git branch -M main
git remote add origin https://github.com/<you>/openhost.git
git push -u origin main
```

### 4. Configure PyPI trusted publishing

For each index (TestPyPI + PyPI), go to **Account settings → Publishing →
Add a new pending publisher** and fill in:

| Field              | Value                        |
|--------------------|------------------------------|
| PyPI Project Name  | `openhost`                   |
| Owner              | `<your GitHub username>`     |
| Repository name    | `openhost`                   |
| Workflow name      | `publish.yml`                |
| Environment name   | `pypi` (or `testpypi`)       |

Do this once for `testpypi` (environment name `testpypi`) and once for `pypi`
(environment name `pypi`).

### 5. Create the GitHub Environments

In the GitHub repo: **Settings → Environments → New environment**.

- `testpypi` — no protection rules needed.
- `pypi` — recommended: add a "Required reviewer" so a human must approve
  every production publish.

## Ship your first release

### Dry run to TestPyPI

1. Go to **Actions → Publish to PyPI → Run workflow**.
2. Select branch `main`, target `testpypi`.
3. Watch it build, check metadata, and publish.
4. Verify the upload:
   ```bash
   pip install -i https://test.pypi.org/simple/ openhost
   python -c "import openhost; openhost.list_presets()"
   ```

### Real release to PyPI

```bash
cd ~/OpenHost/python
# 1. Bump version in pyproject.toml + add CHANGELOG entry
# 2. Commit
git add pyproject.toml CHANGELOG.md
git commit -m "release 0.2.1"
git push

# 3. Tag and push
git tag v0.2.1
git push origin v0.2.1
```

The tag push triggers `publish.yml`:
1. Builds + twine-checks.
2. Verifies the tag matches `pyproject.toml` version (fails loudly if not).
3. Waits for reviewer approval on the `pypi` environment (if configured).
4. Publishes to PyPI via trusted publishing.
5. Creates a GitHub release with auto-generated notes + attaches the wheels.

### Retracting / yanking a release

PyPI won't let you overwrite a version, but you can yank it from the web UI:
<https://pypi.org/manage/project/openhost/releases/>. Yanked versions stay
resolvable (so pins don't break) but don't get picked up by new installs.

## Version strategy

- **Patch** (0.2.x) — bug fixes, docs, new presets, new backend hints
- **Minor** (0.x.0) — new public API (new tools, loaders, endpoints)
- **Major** (x.0.0) — breaking changes to the public API

The current version is defined in `pyproject.toml` as the single source of
truth. `openhost.__version__` reads it implicitly via the top-level string.

Keep `CHANGELOG.md` up to date as part of every release commit.

## Local pre-release checks

Before tagging, run these locally:

```bash
cd ~/OpenHost/python

# Rebuild + validate metadata
rm -rf dist/ build/
python -m build
python -m twine check dist/*

# Install the built wheel in a clean venv, make sure it imports
python -m venv /tmp/openhost-verify
/tmp/openhost-verify/bin/pip install --quiet dist/openhost-*.whl
/tmp/openhost-verify/bin/python -c "import openhost; print(openhost.__version__)"
rm -rf /tmp/openhost-verify
```

## Troubleshooting

**PyPI says "project name already exists".**
The trusted-publisher config references a name that wasn't registered yet. Go
to <https://pypi.org/manage/account/publishing/> and add the pending publisher
BEFORE the first release — after that, it's fine.

**Workflow fails at "Verify tag matches pyproject version".**
You tagged `v0.2.1` but forgot to bump `version = "0.2.1"` in
`pyproject.toml`. Delete the tag (`git tag -d v0.2.1 && git push --delete
origin v0.2.1`), fix, re-tag.

**`pypa/gh-action-pypi-publish` fails with "invalid-token".**
The GitHub Environment name doesn't match what you entered in the PyPI
trusted-publisher form. They must be identical (`pypi` vs `testpypi`).
