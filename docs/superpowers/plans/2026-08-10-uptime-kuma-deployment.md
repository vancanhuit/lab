# Uptime Kuma Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Uptime Kuma 2.5.0 natively on the existing `kuma` Incus container with private HTTPS, local SQLite backups, live verification, and a documented one-time monitoring setup.

**Architecture:** An Ansible role installs Node.js 24 LTS from the signed NodeSource repository, builds a commit-pinned Uptime Kuma release, and runs it as the unprivileged `kuma` account on `127.0.0.1:3001`. Nginx exposes only HTTPS on port 443, while the existing Lego role obtains and renews the certificate. A systemd timer creates validated SQLite online backups, and a separate verification playbook tests the deployed host.

**Tech Stack:** Ansible, Debian 13, Node.js 24 LTS, npm, Uptime Kuma 2.5.0, systemd, Nginx, SQLite, Lego, SOPS

## Global Constraints

- Deploy Uptime Kuma `2.5.0` from verified release commit `d9a60dfc73140d15111752e4e8910ed4b54bd9a3`.
- Install Node.js from NodeSource's signed `node_24.x` repository and reject a runtime whose major is not `24`.
- Verify the NodeSource primary signing-key fingerprint `6F71F525282841EEDAF851B42F59B5F99B1BE0B4`.
- Run the application as the `kuma` system account; keep `uptime-kuma.service` as the unit name.
- Bind Uptime Kuma only to `127.0.0.1:3001`; expose only Nginx HTTPS on port `443`.
- Serve only `kuma.lab.canhdinh.com`; do not expose port 80 or add public ingress.
- Store immutable releases below `/opt/uptime-kuma/releases`, mutable state in `/var/lib/uptime-kuma`, TLS material in `/etc/uptime-kuma/tls`, and backups in `/var/backups/uptime-kuma`.
- Keep 14 daily SQLite online backups and validate every completed backup with `PRAGMA quick_check`.
- Do not automate Kuma 2.5 configuration through its private Socket.IO protocol or by mutating SQLite.
- Keep admin and SMTP secrets in SOPS or Kuma's restricted SQLite database; never print them from Ansible or documentation.
- Follow the existing render-test convention: load defaults under a namespace and backfill only missing variables.

---

### Task 1: Define the Kuma role contract

**Files:**
- Modify: `ansible/inventory.yaml`
- Create: `ansible/roles/uptime_kuma/defaults/main.yaml`
- Create: `ansible/roles/uptime_kuma/tasks/main.yaml`
- Create: `ansible/roles/uptime_kuma/tasks/validate.yaml`
- Create: `ansible/roles/uptime_kuma/tests/render-config.yml`

**Interfaces:**
- Consumes: Debian facts, the existing `lab` inventory group, and role variables supplied by Ansible precedence.
- Produces: The `uptime_kuma_*` variable contract used by every later task and an inventory host named `kuma`.

- [ ] **Step 1: Write the failing role-contract render test**

Create `ansible/roles/uptime_kuma/tests/render-config.yml` with this initial content:

```yaml
---
- name: Validate Uptime Kuma role contract
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_facts:
      distribution: Debian
      distribution_major_version: '13'
      architecture: x86_64
  tasks:
    - name: Load Uptime Kuma role defaults
      ansible.builtin.include_vars:
        file: "{{ (playbook_dir | dirname) ~ '/defaults/main.yaml' }}"
        name: uptime_kuma_role_defaults

    - name: Backfill unset values from role defaults
      ansible.builtin.set_fact:
        uptime_kuma_version: "{{ uptime_kuma_version | default(uptime_kuma_role_defaults.uptime_kuma_version) }}"
        uptime_kuma_release_commit: "{{ uptime_kuma_release_commit | default(uptime_kuma_role_defaults.uptime_kuma_release_commit) }}"
        uptime_kuma_node_major: "{{ uptime_kuma_node_major | default(uptime_kuma_role_defaults.uptime_kuma_node_major) }}"
        uptime_kuma_user: "{{ uptime_kuma_user | default(uptime_kuma_role_defaults.uptime_kuma_user) }}"
        uptime_kuma_group: "{{ uptime_kuma_group | default(uptime_kuma_role_defaults.uptime_kuma_group) }}"
        uptime_kuma_domain: "{{ uptime_kuma_domain | default(uptime_kuma_role_defaults.uptime_kuma_domain) }}"
        uptime_kuma_bind_address: "{{ uptime_kuma_bind_address | default(uptime_kuma_role_defaults.uptime_kuma_bind_address) }}"
        uptime_kuma_port: "{{ uptime_kuma_port | default(uptime_kuma_role_defaults.uptime_kuma_port) }}"
        uptime_kuma_https_port: "{{ uptime_kuma_https_port | default(uptime_kuma_role_defaults.uptime_kuma_https_port) }}"
        uptime_kuma_install_root: "{{ uptime_kuma_install_root | default(uptime_kuma_role_defaults.uptime_kuma_install_root) }}"
        uptime_kuma_release_path: "{{ uptime_kuma_release_path | default(uptime_kuma_role_defaults.uptime_kuma_release_path) }}"
        uptime_kuma_current_path: "{{ uptime_kuma_current_path | default(uptime_kuma_role_defaults.uptime_kuma_current_path) }}"
        uptime_kuma_data_directory: "{{ uptime_kuma_data_directory | default(uptime_kuma_role_defaults.uptime_kuma_data_directory) }}"
        uptime_kuma_backup_directory: "{{ uptime_kuma_backup_directory | default(uptime_kuma_role_defaults.uptime_kuma_backup_directory) }}"
        uptime_kuma_backup_retention_count: "{{ uptime_kuma_backup_retention_count | default(uptime_kuma_role_defaults.uptime_kuma_backup_retention_count) }}"
        uptime_kuma_tls_directory: "{{ uptime_kuma_tls_directory | default(uptime_kuma_role_defaults.uptime_kuma_tls_directory) }}"
        uptime_kuma_tls_cert_path: "{{ uptime_kuma_tls_cert_path | default(uptime_kuma_role_defaults.uptime_kuma_tls_cert_path) }}"
        uptime_kuma_tls_key_path: "{{ uptime_kuma_tls_key_path | default(uptime_kuma_role_defaults.uptime_kuma_tls_key_path) }}"

    - name: Run role validation for positive fixture
      ansible.builtin.import_tasks: "{{ (playbook_dir | dirname) ~ '/tasks/validate.yaml' }}"

    - name: Assert immutable contract values
      ansible.builtin.assert:
        that:
          - uptime_kuma_version == '2.5.0'
          - uptime_kuma_release_commit == 'd9a60dfc73140d15111752e4e8910ed4b54bd9a3'
          - uptime_kuma_node_major | int == 24
          - uptime_kuma_user == 'kuma'
          - uptime_kuma_bind_address == '127.0.0.1'
          - uptime_kuma_port | int == 3001
          - uptime_kuma_https_port | int == 443
          - uptime_kuma_backup_retention_count | int == 14

    - name: Test invalid external bind address
      block:
        - name: Set invalid bind address
          ansible.builtin.set_fact:
            uptime_kuma_bind_address: 0.0.0.0

        - name: Run validation with invalid bind address
          ansible.builtin.include_tasks: "{{ (playbook_dir | dirname) ~ '/tasks/validate.yaml' }}"

        - name: Fail when validation unexpectedly succeeds
          ansible.builtin.fail:
            msg: Validation accepted an externally reachable Kuma listener
      rescue:
        - name: Assert bind-address validation message
          ansible.builtin.assert:
            that:
              - ansible_failed_result.msg is search('uptime_kuma_bind_address must be 127.0.0.1')
      always:
        - name: Restore valid bind address
          ansible.builtin.set_fact:
            uptime_kuma_bind_address: 127.0.0.1
```

- [ ] **Step 2: Run the contract test and verify it fails**

Run:

```bash
cd ansible
ansible-playbook roles/uptime_kuma/tests/render-config.yml
```

Expected: FAIL because `roles/uptime_kuma/defaults/main.yaml` does not exist.

- [ ] **Step 3: Add the role defaults**

Create `ansible/roles/uptime_kuma/defaults/main.yaml`:

```yaml
---
uptime_kuma_version: "2.5.0"
uptime_kuma_release_commit: d9a60dfc73140d15111752e4e8910ed4b54bd9a3
uptime_kuma_repository_url: https://github.com/louislam/uptime-kuma.git
uptime_kuma_node_major: 24
uptime_kuma_nodesource_key_url: https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
uptime_kuma_nodesource_key_fingerprint: 6F71F525282841EEDAF851B42F59B5F99B1BE0B4
uptime_kuma_user: kuma
uptime_kuma_group: kuma
uptime_kuma_admin_username: kuma-admin
uptime_kuma_domain: kuma.lab.canhdinh.com
uptime_kuma_bind_address: 127.0.0.1
uptime_kuma_port: 3001
uptime_kuma_https_port: 443
uptime_kuma_install_root: /opt/uptime-kuma
uptime_kuma_release_path: "{{ uptime_kuma_install_root }}/releases/{{ uptime_kuma_release_commit }}"
uptime_kuma_current_path: "{{ uptime_kuma_install_root }}/current"
uptime_kuma_data_directory: /var/lib/uptime-kuma
uptime_kuma_npm_cache_directory: /var/cache/uptime-kuma
uptime_kuma_backup_directory: /var/backups/uptime-kuma
uptime_kuma_backup_retention_count: 14
uptime_kuma_backup_calendar: daily
uptime_kuma_backup_randomized_delay: 1h
uptime_kuma_tls_directory: /etc/uptime-kuma/tls
uptime_kuma_tls_cert_path: /etc/uptime-kuma/tls/server.crt
uptime_kuma_tls_key_path: /etc/uptime-kuma/tls/server.key
```

- [ ] **Step 4: Implement fail-fast validation**

Create `ansible/roles/uptime_kuma/tasks/validate.yaml` with assertions for Debian 13, `x86_64`/`aarch64`, the exact Kuma version and 40-character commit, Node major 24, `kuma` user/group, loopback bind, ports 3001/443, the exact hostname, absolute non-overlapping paths, and positive backup retention. Use this concrete assertion shape:

```yaml
---
- name: Assert Debian 13 is required
  ansible.builtin.assert:
    that:
      - ansible_facts.distribution == 'Debian'
      - ansible_facts.distribution_major_version == '13'
    fail_msg: Uptime Kuma role requires Debian 13
    quiet: true

- name: Assert supported architecture
  ansible.builtin.assert:
    that:
      - ansible_facts.architecture in ['x86_64', 'aarch64']
    fail_msg: Uptime Kuma role requires x86_64 or aarch64
    quiet: true

- name: Assert pinned application and runtime versions
  ansible.builtin.assert:
    that:
      - uptime_kuma_version == '2.5.0'
      - uptime_kuma_release_commit is match('^[0-9a-f]{40}$')
      - uptime_kuma_release_commit == 'd9a60dfc73140d15111752e4e8910ed4b54bd9a3'
      - uptime_kuma_node_major | int == 24
    fail_msg: This role is validated only for Uptime Kuma 2.5.0 on Node.js 24
    quiet: true

- name: Assert service identity
  ansible.builtin.assert:
    that:
      - uptime_kuma_user == 'kuma'
      - uptime_kuma_group == 'kuma'
    fail_msg: Uptime Kuma must run as the kuma system account
    quiet: true

- name: Assert private listener and public HTTPS ports
  ansible.builtin.assert:
    that:
      - uptime_kuma_bind_address == '127.0.0.1'
      - uptime_kuma_port | int == 3001
      - uptime_kuma_https_port | int == 443
    fail_msg: uptime_kuma_bind_address must be 127.0.0.1 and ports must be 3001/443
    quiet: true

- name: Assert hostname and backup retention
  ansible.builtin.assert:
    that:
      - uptime_kuma_domain == 'kuma.lab.canhdinh.com'
      - uptime_kuma_backup_retention_count | int == 14
    fail_msg: Kuma hostname or backup retention differs from the approved design
    quiet: true

- name: Assert managed paths are absolute and distinct
  ansible.builtin.assert:
    that:
      - item is match('^/')
      - item != '/'
  loop:
    - "{{ uptime_kuma_install_root }}"
    - "{{ uptime_kuma_data_directory }}"
    - "{{ uptime_kuma_backup_directory }}"
    - "{{ uptime_kuma_tls_directory }}"
  loop_control:
    label: "{{ item }}"
  quiet: true

- name: Assert managed directories do not overlap
  ansible.builtin.assert:
    that:
      - >-
        [uptime_kuma_install_root, uptime_kuma_data_directory,
         uptime_kuma_backup_directory, uptime_kuma_tls_directory] |
        unique | length == 4
    fail_msg: Uptime Kuma install, data, backup, and TLS paths must be distinct
    quiet: true
```

Create `ansible/roles/uptime_kuma/tasks/main.yaml`:

```yaml
---
- name: Import validation tasks
  ansible.builtin.import_tasks: validate.yaml
```

- [ ] **Step 5: Add the Kuma inventory host**

Add this host beside `gitea` in `ansible/inventory.yaml`:

```yaml
    kuma:
      ansible_host: kuma.lab.canhdinh.com
```

- [ ] **Step 6: Run the contract test and inventory parser**

Run:

```bash
cd ansible
ansible-playbook roles/uptime_kuma/tests/render-config.yml
ansible-inventory --graph
```

Expected: the render test passes and `@lab` contains `kuma`.

- [ ] **Step 7: Commit the role contract**

```bash
git add ansible/inventory.yaml ansible/roles/uptime_kuma
git commit -m "feat(kuma): define deployment role contract"
```

---

### Task 2: Install Node.js and build pinned releases

**Files:**
- Modify: `ansible/roles/uptime_kuma/tasks/main.yaml`
- Create: `ansible/roles/uptime_kuma/tasks/install.yaml`
- Create: `ansible/roles/uptime_kuma/tasks/release.yaml`
- Modify: `ansible/roles/uptime_kuma/tests/render-config.yml`

**Interfaces:**
- Consumes: The Task 1 role defaults and validation contract.
- Produces: A verified release at `uptime_kuma_release_path` and an atomic `uptime_kuma_current_path` symlink for systemd.

- [ ] **Step 1: Extend the render test with failing installation assertions**

Append tasks that slurp and parse `tasks/install.yaml` and `tasks/release.yaml`, then assert the files contain these controls:

```yaml
    - name: Read installation task files
      ansible.builtin.slurp:
        src: "{{ item }}"
      loop:
        - "{{ (playbook_dir | dirname) ~ '/tasks/install.yaml' }}"
        - "{{ (playbook_dir | dirname) ~ '/tasks/release.yaml' }}"
      register: uptime_kuma_install_task_files

    - name: Combine installation task content
      ansible.builtin.set_fact:
        uptime_kuma_install_tasks_rendered: >-
          {{ uptime_kuma_install_task_files.results |
             map(attribute='content') |
             map('b64decode') |
             join('\n') }}

    - name: Assert installation trust and release controls
      ansible.builtin.assert:
        that:
          - uptime_kuma_install_tasks_rendered is search('nodesource-repo\.gpg\.key')
          - uptime_kuma_install_tasks_rendered is search('6F71F525282841EEDAF851B42F59B5F99B1BE0B4')
          - uptime_kuma_install_tasks_rendered is search('node_.*\.x')
          - uptime_kuma_install_tasks_rendered is search('npm ci --omit=dev --no-audit')
          - uptime_kuma_install_tasks_rendered is search('npm run download-dist')
          - uptime_kuma_install_tasks_rendered is search('uptime_kuma_release_commit')
          - uptime_kuma_install_tasks_rendered is search('state: link')
```

- [ ] **Step 2: Run the render test and verify it fails**

Run:

```bash
cd ansible
ansible-playbook roles/uptime_kuma/tests/render-config.yml
```

Expected: FAIL because `tasks/install.yaml` and `tasks/release.yaml` do not exist.

- [ ] **Step 3: Implement trusted NodeSource installation and service identity**

Create `tasks/install.yaml` with these ordered operations:

```yaml
---
- name: Install Uptime Kuma operating-system dependencies
  ansible.builtin.apt:
    name:
      - acl
      - build-essential
      - ca-certificates
      - curl
      - git
      - gnupg
      - nginx
      - openssl
      - python3
      - sqlite3
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Create APT keyring directory
  ansible.builtin.file:
    path: /usr/share/keyrings
    state: directory
    owner: root
    group: root
    mode: '0755'

- name: Download NodeSource repository key
  ansible.builtin.get_url:
    url: "{{ uptime_kuma_nodesource_key_url }}"
    dest: /usr/share/keyrings/nodesource-repo.asc
    owner: root
    group: root
    mode: '0644'

- name: Read NodeSource repository key fingerprint
  ansible.builtin.command:
    cmd: gpg --batch --show-keys --with-colons /usr/share/keyrings/nodesource-repo.asc
  register: uptime_kuma_nodesource_key_check
  changed_when: false
  failed_when: >-
    'fpr:::::::::' ~ uptime_kuma_nodesource_key_fingerprint ~ ':'
    not in uptime_kuma_nodesource_key_check.stdout

- name: Configure NodeSource Node.js repository
  ansible.builtin.apt_repository:
    repo: >-
      deb [arch={{ ansible_facts.architecture | regex_replace('^x86_64$', 'amd64') | regex_replace('^aarch64$', 'arm64') }}
      signed-by=/usr/share/keyrings/nodesource-repo.asc]
      https://deb.nodesource.com/node_{{ uptime_kuma_node_major }}.x nodistro main
    filename: nodesource
    state: present
    update_cache: true

- name: Install Node.js 24 LTS
  ansible.builtin.apt:
    name: nodejs
    state: latest
  notify: Restart Uptime Kuma

- name: Check installed Node.js version
  ansible.builtin.command:
    cmd: node --version
  register: uptime_kuma_node_version_check
  changed_when: false
  failed_when: uptime_kuma_node_version_check.stdout is not match('^v24\.')

- name: Create Uptime Kuma system group
  ansible.builtin.group:
    name: "{{ uptime_kuma_group }}"
    system: true
    state: present

- name: Create Uptime Kuma system user
  ansible.builtin.user:
    name: "{{ uptime_kuma_user }}"
    group: "{{ uptime_kuma_group }}"
    home: "{{ uptime_kuma_data_directory }}"
    shell: /usr/sbin/nologin
    system: true
    create_home: false
    state: present

- name: Create Uptime Kuma managed directories
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner }}"
    group: "{{ item.group }}"
    mode: "{{ item.mode }}"
  loop:
    - { path: "{{ uptime_kuma_install_root }}", owner: root, group: root, mode: '0755' }
    - { path: "{{ uptime_kuma_install_root }}/releases", owner: root, group: root, mode: '0755' }
    - { path: "{{ uptime_kuma_data_directory }}", owner: "{{ uptime_kuma_user }}", group: "{{ uptime_kuma_group }}", mode: '0700' }
    - { path: "{{ uptime_kuma_npm_cache_directory }}", owner: "{{ uptime_kuma_user }}", group: "{{ uptime_kuma_group }}", mode: '0700' }

- name: Create pinned release directory
  ansible.builtin.file:
    path: "{{ uptime_kuma_release_path }}"
    state: directory
    owner: "{{ uptime_kuma_user }}"
    group: "{{ uptime_kuma_group }}"
    mode: '0755'
```

- [ ] **Step 4: Implement versioned release building and activation**

Create `tasks/release.yaml`. Use `ansible.builtin.git` as `kuma`, run npm from the release working directory with a private cache, verify `package.json`, and activate only after both dependency and frontend steps succeed:

```yaml
---
- name: Check active release symlink
  ansible.builtin.stat:
    path: "{{ uptime_kuma_current_path }}"
    follow: false
  register: uptime_kuma_current_link

- name: Check out pinned Uptime Kuma release
  ansible.builtin.git:
    repo: "{{ uptime_kuma_repository_url }}"
    dest: "{{ uptime_kuma_release_path }}"
    version: "{{ uptime_kuma_release_commit }}"
    force: false
  become: true
  become_user: "{{ uptime_kuma_user }}"

- name: Install locked production dependencies
  ansible.builtin.command:
    cmd: npm ci --omit=dev --no-audit
    chdir: "{{ uptime_kuma_release_path }}"
    creates: "{{ uptime_kuma_release_path }}/node_modules"
  become: true
  become_user: "{{ uptime_kuma_user }}"
  environment:
    HOME: "{{ uptime_kuma_data_directory }}"
    npm_config_cache: "{{ uptime_kuma_npm_cache_directory }}"

- name: Download matching Uptime Kuma frontend
  ansible.builtin.command:
    cmd: npm run download-dist
    chdir: "{{ uptime_kuma_release_path }}"
    creates: "{{ uptime_kuma_release_path }}/dist/index.html"
  become: true
  become_user: "{{ uptime_kuma_user }}"
  environment:
    HOME: "{{ uptime_kuma_data_directory }}"
    npm_config_cache: "{{ uptime_kuma_npm_cache_directory }}"

- name: Verify checked-out Uptime Kuma version
  ansible.builtin.command:
    argv:
      - node
      - -p
      - require('./package.json').version
  args:
    chdir: "{{ uptime_kuma_release_path }}"
  register: uptime_kuma_package_version_check
  changed_when: false
  failed_when: uptime_kuma_package_version_check.stdout != uptime_kuma_version

- name: Activate verified Uptime Kuma release
  ansible.builtin.file:
    src: "{{ uptime_kuma_release_path }}"
    dest: "{{ uptime_kuma_current_path }}"
    state: link
    owner: root
    group: root
  notify: Restart Uptime Kuma
```

Add release-directory discovery and removal after the readiness gate in Task 3. Keep the active release plus the newest non-active release:

```yaml
- name: Find installed Uptime Kuma releases
  ansible.builtin.find:
    paths: "{{ uptime_kuma_install_root }}/releases"
    file_type: directory
    recurse: false
  register: uptime_kuma_installed_releases

- name: Select previous Uptime Kuma release
  ansible.builtin.set_fact:
    uptime_kuma_previous_releases: >-
      {{ uptime_kuma_installed_releases.files |
         rejectattr('path', 'equalto', uptime_kuma_release_path) |
         sort(attribute='mtime', reverse=true) |
         map(attribute='path') |
         list }}

- name: Remove obsolete Uptime Kuma releases
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop: >-
    {{ uptime_kuma_previous_releases[1:] }}
  loop_control:
    label: "{{ item }}"
```

- [ ] **Step 5: Import installation and release tasks**

Extend `tasks/main.yaml`:

```yaml
- name: Import installation tasks
  ansible.builtin.import_tasks: install.yaml

- name: Import release tasks
  ansible.builtin.import_tasks: release.yaml
```

Create `handlers/main.yaml` now so activation notifications have a defined target after Task 3 installs the unit:

```yaml
---
- name: Reload systemd daemon
  ansible.builtin.systemd_service:
    daemon_reload: true

- name: Restart Uptime Kuma
  ansible.builtin.systemd_service:
    name: uptime-kuma.service
    state: restarted
```

- [ ] **Step 6: Run focused static checks**

Run:

```bash
cd ansible
ansible-playbook roles/uptime_kuma/tests/render-config.yml
ansible-playbook --syntax-check roles/uptime_kuma/tests/render-config.yml
```

Expected: both commands pass. Do not run the role on `kuma` until Task 5 adds complete live verification.

- [ ] **Step 7: Commit native installation support**

```bash
git add ansible/roles/uptime_kuma
git commit -m "feat(kuma): install pinned native release"
```

---

### Task 3: Add systemd, Nginx, and Lego TLS

**Files:**
- Modify: `ansible/roles/uptime_kuma/tasks/main.yaml`
- Create: `ansible/roles/uptime_kuma/tasks/runtime.yaml`
- Modify: `ansible/roles/uptime_kuma/handlers/main.yaml`
- Create: `ansible/roles/uptime_kuma/templates/uptime-kuma.service.j2`
- Create: `ansible/roles/uptime_kuma/templates/nginx.conf.j2`
- Create: `ansible/roles/uptime_kuma/templates/lego-deploy-hook.sh.j2`
- Modify: `ansible/roles/uptime_kuma/tests/render-config.yml`
- Create: `ansible/kuma.yaml`

**Interfaces:**
- Consumes: Task 2's active-release symlink, `uptime_kuma_*` paths, and the shared Lego role's `lego_hooks.deploy.script` contract.
- Produces: `uptime-kuma.service`, loopback port 3001, Nginx HTTPS port 443, and atomic certificate deployment.

- [ ] **Step 1: Add failing template-render checks**

Extend the render playbook to render all three templates into its temporary directory, slurp them, and assert:

```yaml
    - name: Assert systemd service properties
      ansible.builtin.assert:
        that:
          - uptime_kuma_service_rendered is search('User=kuma')
          - uptime_kuma_service_rendered is search('Group=kuma')
          - uptime_kuma_service_rendered is search('UPTIME_KUMA_HOST=127\.0\.0\.1')
          - uptime_kuma_service_rendered is search('UPTIME_KUMA_PORT=3001')
          - uptime_kuma_service_rendered is search('DATA_DIR=/var/lib/uptime-kuma')
          - uptime_kuma_service_rendered is search('ExecStart=/usr/bin/node server/server\.js')

    - name: Assert Nginx reverse-proxy properties
      ansible.builtin.assert:
        that:
          - uptime_kuma_nginx_rendered is search('listen 443 ssl')
          - uptime_kuma_nginx_rendered is not search('listen 80')
          - uptime_kuma_nginx_rendered is search('server_name kuma\.lab\.canhdinh\.com')
          - uptime_kuma_nginx_rendered is search('proxy_pass http://127\.0\.0\.1:3001')
          - uptime_kuma_nginx_rendered is search('proxy_set_header Upgrade')
          - uptime_kuma_nginx_rendered is search('proxy_set_header Connection')

    - name: Assert certificate hook safety properties
      ansible.builtin.assert:
        that:
          - uptime_kuma_hook_rendered is search('/var/lib/lego/certificates/kuma\.crt')
          - uptime_kuma_hook_rendered is search('openssl x509')
          - uptime_kuma_hook_rendered is search('openssl pkey')
          - uptime_kuma_hook_rendered is search('nginx -t')
          - uptime_kuma_hook_rendered is search('systemctl reload nginx\.service')
```

- [ ] **Step 2: Run the render test and verify it fails**

Run:

```bash
cd ansible
ansible-playbook roles/uptime_kuma/tests/render-config.yml
```

Expected: FAIL because the service, Nginx, and hook templates do not exist.

- [ ] **Step 3: Create the hardened systemd service**

Create `templates/uptime-kuma.service.j2`:

```ini
[Unit]
Description=Uptime Kuma monitoring service
Documentation=https://github.com/louislam/uptime-kuma
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User={{ uptime_kuma_user }}
Group={{ uptime_kuma_group }}
WorkingDirectory={{ uptime_kuma_current_path }}
Environment=NODE_ENV=production
Environment=UPTIME_KUMA_HOST={{ uptime_kuma_bind_address }}
Environment=UPTIME_KUMA_PORT={{ uptime_kuma_port }}
Environment=DATA_DIR={{ uptime_kuma_data_directory }}
ExecStart=/usr/bin/node server/server.js
Restart=on-failure
RestartSec=5s
UMask=0077
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths={{ uptime_kuma_data_directory }}

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Create the Nginx WebSocket reverse proxy**

Create `templates/nginx.conf.j2`:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen {{ uptime_kuma_https_port }} ssl;
    listen [::]:{{ uptime_kuma_https_port }} ssl;
    server_name {{ uptime_kuma_domain }};

    ssl_certificate {{ uptime_kuma_tls_cert_path }};
    ssl_certificate_key {{ uptime_kuma_tls_key_path }};
    ssl_protocols TLSv1.2 TLSv1.3;

    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
    add_header X-Frame-Options SAMEORIGIN always;

    location / {
        proxy_pass http://{{ uptime_kuma_bind_address }}:{{ uptime_kuma_port }};
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }
}
```

- [ ] **Step 5: Create the atomic Lego certificate hook**

Create `templates/lego-deploy-hook.sh.j2`:

```sh
#!/bin/sh
set -eu
umask 077

SRC_CRT=/var/lib/lego/certificates/kuma.crt
SRC_KEY=/var/lib/lego/certificates/kuma.key
DST_CRT={{ uptime_kuma_tls_cert_path }}
DST_KEY={{ uptime_kuma_tls_key_path }}
NEW_CRT="${DST_CRT}.new"
NEW_KEY="${DST_KEY}.new"

cleanup() {
  rm -f "$NEW_CRT" "$NEW_KEY"
}
trap cleanup EXIT HUP INT TERM

if ! openssl x509 -in "$SRC_CRT" -checkend 0 -noout; then
  echo "ERROR: Uptime Kuma certificate is expired or invalid" >&2
  exit 1
fi

cert_digest="$(openssl x509 -in "$SRC_CRT" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
key_digest="$(openssl pkey -in "$SRC_KEY" -pubout -outform DER | sha256sum | awk '{print $1}')"

if [ "$cert_digest" != "$key_digest" ]; then
  echo "ERROR: Uptime Kuma certificate and key do not match" >&2
  exit 1
fi

install -o root -g root -m 0644 "$SRC_CRT" "$NEW_CRT"
install -o root -g www-data -m 0640 "$SRC_KEY" "$NEW_KEY"
mv -f "$NEW_CRT" "$DST_CRT"
mv -f "$NEW_KEY" "$DST_KEY"

/usr/sbin/nginx -t
systemctl reload nginx.service
```

Do not print certificate private-key material.

- [ ] **Step 6: Implement runtime tasks and handlers**

Create `tasks/runtime.yaml` with these tasks, followed by the exact release-retention block from Task 2:

```yaml
---
- name: Create Uptime Kuma TLS directory
  ansible.builtin.file:
    path: "{{ uptime_kuma_tls_directory }}"
    state: directory
    owner: root
    group: www-data
    mode: '0750'

- name: Check Uptime Kuma TLS certificate
  ansible.builtin.stat:
    path: "{{ uptime_kuma_tls_cert_path }}"
  register: uptime_kuma_tls_cert_state

- name: Check Uptime Kuma TLS key
  ansible.builtin.stat:
    path: "{{ uptime_kuma_tls_key_path }}"
  register: uptime_kuma_tls_key_state

- name: Reject partial Uptime Kuma TLS state
  ansible.builtin.assert:
    that:
      - uptime_kuma_tls_cert_state.stat.exists == uptime_kuma_tls_key_state.stat.exists
    fail_msg: Uptime Kuma TLS certificate and key must both exist or both be absent

- name: Seed Uptime Kuma TLS certificate
  ansible.builtin.copy:
    src: /etc/ssl/certs/ssl-cert-snakeoil.pem
    dest: "{{ uptime_kuma_tls_cert_path }}"
    remote_src: true
    owner: root
    group: root
    mode: '0644'
  when: not uptime_kuma_tls_cert_state.stat.exists

- name: Seed Uptime Kuma TLS key
  ansible.builtin.copy:
    src: /etc/ssl/private/ssl-cert-snakeoil.key
    dest: "{{ uptime_kuma_tls_key_path }}"
    remote_src: true
    owner: root
    group: www-data
    mode: '0640'
  when: not uptime_kuma_tls_key_state.stat.exists

- name: Render Uptime Kuma systemd service
  ansible.builtin.template:
    src: uptime-kuma.service.j2
    dest: /etc/systemd/system/uptime-kuma.service
    owner: root
    group: root
    mode: '0644'
  notify:
    - Reload systemd daemon
    - Restart Uptime Kuma

- name: Render Uptime Kuma Nginx site
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/sites-available/uptime-kuma
    owner: root
    group: root
    mode: '0644'
  notify: Reload Nginx

- name: Disable default Nginx site
  ansible.builtin.file:
    path: /etc/nginx/sites-enabled/default
    state: absent
  notify: Reload Nginx

- name: Enable Uptime Kuma Nginx site
  ansible.builtin.file:
    src: /etc/nginx/sites-available/uptime-kuma
    dest: /etc/nginx/sites-enabled/uptime-kuma
    state: link
  notify: Reload Nginx

- name: Flush runtime handlers
  ansible.builtin.meta: flush_handlers

- name: Enable and start Uptime Kuma
  ansible.builtin.systemd_service:
    name: uptime-kuma.service
    enabled: true
    state: started

- name: Enable and start Nginx
  ansible.builtin.systemd_service:
    name: nginx.service
    enabled: true
    state: started

- name: Wait for private Uptime Kuma listener
  ansible.builtin.wait_for:
    host: "{{ uptime_kuma_bind_address }}"
    port: "{{ uptime_kuma_port }}"
    state: started
    timeout: 120

- name: Wait for Nginx HTTPS listener
  ansible.builtin.wait_for:
    host: 127.0.0.1
    port: "{{ uptime_kuma_https_port }}"
    state: started
    timeout: 60
```

Use two ordered handlers on the same notification topic so configuration validation completes before reload:

```yaml
- name: Validate Nginx configuration
  ansible.builtin.command:
    cmd: /usr/sbin/nginx -t
  changed_when: false
  listen: Reload Nginx

- name: Reload Nginx service
  ansible.builtin.systemd_service:
    name: nginx.service
    state: reloaded
  listen: Reload Nginx
```

Import `runtime.yaml` after `release.yaml` in `tasks/main.yaml`.

- [ ] **Step 7: Add the deployment playbook**

Create `ansible/kuma.yaml`:

```yaml
---
- name: Deploy Uptime Kuma with private HTTPS
  hosts: kuma
  become: true
  vars:
    lego_domain_names:
      - kuma.lab.canhdinh.com
    lego_certificate_name: kuma
    lego_hooks:
      deploy:
        script: "{{ lookup('ansible.builtin.template', playbook_dir ~ '/roles/uptime_kuma/templates/lego-deploy-hook.sh.j2') }}"
  roles:
    - uptime_kuma
    - lego
```

- [ ] **Step 8: Run focused template and syntax checks**

Run:

```bash
cd ansible
ansible-playbook roles/uptime_kuma/tests/render-config.yml
ansible-playbook kuma.yaml --syntax-check
```

Expected: both pass. The render test must run `sh -n` against the rendered hook and assert the complete Nginx directives without requiring Nginx on the controller.

- [ ] **Step 9: Commit runtime and HTTPS support**

```bash
git add ansible/kuma.yaml ansible/roles/uptime_kuma
git commit -m "feat(kuma): add private HTTPS runtime"
```

---

### Task 4: Add validated SQLite backups

**Files:**
- Modify: `ansible/roles/uptime_kuma/tasks/main.yaml`
- Modify: `ansible/roles/uptime_kuma/tasks/release.yaml`
- Create: `ansible/roles/uptime_kuma/tasks/backup.yaml`
- Create: `ansible/roles/uptime_kuma/templates/uptime-kuma-backup.sh.j2`
- Create: `ansible/roles/uptime_kuma/templates/uptime-kuma-backup.service.j2`
- Create: `ansible/roles/uptime_kuma/templates/uptime-kuma-backup.timer.j2`
- Modify: `ansible/roles/uptime_kuma/tests/render-config.yml`

**Interfaces:**
- Consumes: `DATA_DIR`, the SQLite database at `/var/lib/uptime-kuma/kuma.db`, and systemd.
- Produces: `uptime-kuma-backup.service`, `uptime-kuma-backup.timer`, and validated root-only archives under `/var/backups/uptime-kuma`.

- [ ] **Step 1: Add failing backup render checks**

Render the script and both units in `render-config.yml`, then assert:

```yaml
    - name: Assert backup script properties
      ansible.builtin.assert:
        that:
          - uptime_kuma_backup_script_rendered is search('sqlite3 .* \.backup')
          - uptime_kuma_backup_script_rendered is search('PRAGMA quick_check')
          - uptime_kuma_backup_script_rendered is search('gzip')
          - uptime_kuma_backup_script_rendered is search('awk -v keep=')
          - uptime_kuma_backup_service_rendered is search('Type=oneshot')
          - uptime_kuma_backup_timer_rendered is search('OnCalendar=daily')
          - uptime_kuma_backup_timer_rendered is search('Persistent=true')
          - uptime_kuma_backup_timer_rendered is search('RandomizedDelaySec=1h')
```

- [ ] **Step 2: Run the render test and verify it fails**

Run:

```bash
cd ansible
ansible-playbook roles/uptime_kuma/tests/render-config.yml
```

Expected: FAIL because the backup templates do not exist.

- [ ] **Step 3: Create the online-backup script**

Create `templates/uptime-kuma-backup.sh.j2`:

```sh
#!/bin/sh
set -eu
umask 077

DATA_DIR="{{ uptime_kuma_data_directory }}"
BACKUP_DIR="{{ uptime_kuma_backup_directory }}"
RETENTION_COUNT="{{ uptime_kuma_backup_retention_count }}"
DATABASE="$DATA_DIR/kuma.db"

if [ ! -f "$DATABASE" ]; then
    echo "Uptime Kuma database does not exist yet; nothing to back up"
    exit 0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
temporary_database="$BACKUP_DIR/.kuma-$timestamp.db.tmp"
temporary_archive="$BACKUP_DIR/.kuma-$timestamp.db.gz.tmp"
final_archive="$BACKUP_DIR/kuma-$timestamp.db.gz"

cleanup() {
    rm -f "$temporary_database" "$temporary_archive"
}
trap cleanup EXIT HUP INT TERM

sqlite3 "$DATABASE" ".backup '$temporary_database'"
test "$(sqlite3 "$temporary_database" 'PRAGMA quick_check;')" = "ok"
gzip -c "$temporary_database" > "$temporary_archive"
mv -f "$temporary_archive" "$final_archive"
find "$BACKUP_DIR" -type f -name 'kuma-*.db.gz' -printf '%T@ %p\n' |
  sort -nr |
  awk -v keep="$RETENTION_COUNT" 'NR > keep { $1=""; sub(/^ /, ""); print }' |
  while IFS= read -r expired_archive; do
    rm -f -- "$expired_archive"
  done
```

- [ ] **Step 4: Create backup units and management tasks**

Create `templates/uptime-kuma-backup.service.j2`:

```ini
[Unit]
Description=Back up the Uptime Kuma SQLite database
After=local-fs.target

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/local/sbin/uptime-kuma-backup
```

Create `templates/uptime-kuma-backup.timer.j2`:

```ini
[Unit]
Description=Daily Uptime Kuma SQLite backup timer

[Timer]
OnCalendar={{ uptime_kuma_backup_calendar }}
Persistent=true
RandomizedDelaySec={{ uptime_kuma_backup_randomized_delay }}
Unit=uptime-kuma-backup.service

[Install]
WantedBy=timers.target
```

Create `tasks/backup.yaml` to create `/var/backups/uptime-kuma` as `root:root 0700`, render the script as `0750`, render both units as `0644`, notify `Reload systemd daemon` when units change, flush handlers, and enable/start `uptime-kuma-backup.timer`.

Import `backup.yaml` after `install.yaml` and before `release.yaml` in `tasks/main.yaml`.

- [ ] **Step 5: Add pre-upgrade backup gating**

In `release.yaml`, compute whether the active symlink target differs from `uptime_kuma_release_path`. Before changing the symlink:

```yaml
- name: Check Uptime Kuma database state
  ansible.builtin.stat:
    path: "{{ uptime_kuma_data_directory }}/kuma.db"
  register: uptime_kuma_database_state

- name: Determine whether release activation is required
  ansible.builtin.set_fact:
    uptime_kuma_release_activation_required: >-
      {{ not uptime_kuma_current_link.stat.exists or
         uptime_kuma_current_link.stat.lnk_source | default('') != uptime_kuma_release_path }}

- name: Back up Uptime Kuma before release activation
  ansible.builtin.systemd_service:
    name: uptime-kuma-backup.service
    state: started
  when:
    - uptime_kuma_database_state.stat.exists
    - uptime_kuma_release_activation_required
```

A routine idempotent run must not create a backup or report a changed activation.

- [ ] **Step 6: Validate backup rendering and shell syntax**

Run:

```bash
cd ansible
ansible-playbook roles/uptime_kuma/tests/render-config.yml
ansible-playbook kuma.yaml --syntax-check
```

Expected: PASS. The render playbook must execute `sh -n` on the rendered backup script.

- [ ] **Step 7: Commit backup automation**

```bash
git add ansible/roles/uptime_kuma
git commit -m "feat(kuma): add validated sqlite backups"
```

---

### Task 5: Add live deployment verification

**Files:**
- Create: `ansible/verify-kuma.yaml`
- Modify: `ansible/roles/uptime_kuma/tests/render-config.yml`

**Interfaces:**
- Consumes: The complete Kuma role, Nginx/Lego deployment, systemd units, and live DNS.
- Produces: A repeatable acceptance check for runtime versions, listener boundaries, TLS, data permissions, and restorable backups.

- [ ] **Step 1: Add failing verification and listener tests**

Add a `slurp` of `ansible/verify-kuma.yaml` so the test fails while that file is absent. Add these listener fixtures and predicates to protect the exact regex later used by the verification playbook:

```yaml
    - name: Define listener fixtures
      ansible.builtin.set_fact:
        uptime_kuma_ss_valid: |
          LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=100,fd=5))
          LISTEN 0 511 127.0.0.1:3001 0.0.0.0:* users:(("node",pid=200,fd=20))
        uptime_kuma_ss_invalid_ipv4: |
          LISTEN 0 511 0.0.0.0:3001 0.0.0.0:* users:(("node",pid=200,fd=20))
        uptime_kuma_ss_invalid_ipv6: |
          LISTEN 0 511 [::]:3001 [::]:* users:(("node",pid=200,fd=20))

    - name: Assert listener boundary predicates
      ansible.builtin.assert:
        that:
          - uptime_kuma_ss_valid is regex('(?m)^.*127\\.0\\.0\\.1:3001\\b.*node')
          - uptime_kuma_ss_valid is regex('(?m)^.*:443\\b.*nginx')
          - uptime_kuma_ss_valid is not regex('(?m)^.*(?:0\\.0\\.0\\.0|\\*|\\[::\\]):3001\\b')
          - uptime_kuma_ss_invalid_ipv4 is regex('(?m)^.*(?:0\\.0\\.0\\.0|\\*|\\[::\\]):3001\\b')
          - uptime_kuma_ss_invalid_ipv6 is regex('(?m)^.*(?:0\\.0\\.0\\.0|\\*|\\[::\\]):3001\\b')
```

- [ ] **Step 2: Run the fixture test and verify it fails**

Run:

```bash
cd ansible
ansible-playbook roles/uptime_kuma/tests/render-config.yml
```

Expected: FAIL because `ansible/verify-kuma.yaml` does not exist.

- [ ] **Step 3: Create the live verification playbook**

Create `ansible/verify-kuma.yaml` with the following task structure. Use the listener predicates from Step 1 verbatim:

```yaml
---
- name: Verify Uptime Kuma deployment
  hosts: kuma
  become: true
  tasks:
    - name: Check Node.js version
      ansible.builtin.command:
        cmd: node --version
      register: uptime_kuma_node_check
      changed_when: false
      failed_when: uptime_kuma_node_check.stdout is not match('^v24\\.')

    - name: Check Uptime Kuma version
      ansible.builtin.command:
        argv:
          - node
          - -p
          - require('/opt/uptime-kuma/current/package.json').version
      register: uptime_kuma_version_check
      changed_when: false
      failed_when: uptime_kuma_version_check.stdout != '2.5.0'

    - name: Gather service facts
      ansible.builtin.service_facts:

    - name: Assert required services and timers
      ansible.builtin.assert:
        that:
          - ansible_facts.services['uptime-kuma.service'].state == 'running'
          - ansible_facts.services['uptime-kuma.service'].status == 'enabled'
          - ansible_facts.services['nginx.service'].state == 'running'
          - ansible_facts.services['nginx.service'].status == 'enabled'
          - ansible_facts.services['lego-renew.timer'].state == 'running'
          - ansible_facts.services['lego-renew.timer'].status == 'enabled'
          - ansible_facts.services['uptime-kuma-backup.timer'].state == 'running'
          - ansible_facts.services['uptime-kuma-backup.timer'].status == 'enabled'

    - name: Read TCP listeners
      ansible.builtin.command:
        cmd: ss -H -ltnp
      register: uptime_kuma_listener_check
      changed_when: false

    - name: Assert listener boundaries
      ansible.builtin.assert:
        that:
          - uptime_kuma_listener_check.stdout is regex('(?m)^.*127\\.0\\.0\\.1:3001\\b.*node')
          - uptime_kuma_listener_check.stdout is regex('(?m)^.*:443\\b.*nginx')
          - uptime_kuma_listener_check.stdout is not regex('(?m)^.*(?:0\\.0\\.0\\.0|\\*|\\[::\\]):3001\\b')

    - name: Validate Nginx configuration
      ansible.builtin.command:
        cmd: /usr/sbin/nginx -t
      changed_when: false

    - name: Check Kuma HTTPS endpoint
      ansible.builtin.uri:
        url: https://kuma.lab.canhdinh.com/
        validate_certs: true
        follow_redirects: none
        status_code: [200, 302]
      changed_when: false

    - name: Check certificate validity and subject alternative name
      ansible.builtin.shell:
        cmd: |
          set -o pipefail
          openssl s_client -connect kuma.lab.canhdinh.com:443 \
            -servername kuma.lab.canhdinh.com </dev/null 2>/dev/null |
            openssl x509 -checkend 604800 -noout -ext subjectAltName
        executable: /bin/bash
      register: uptime_kuma_certificate_check
      changed_when: false
      failed_when: >-
        uptime_kuma_certificate_check.rc != 0 or
        'DNS:kuma.lab.canhdinh.com' not in uptime_kuma_certificate_check.stdout

    - name: Read protected path metadata
      ansible.builtin.stat:
        path: "{{ item }}"
      loop:
        - /var/lib/uptime-kuma
        - /var/backups/uptime-kuma
        - /etc/uptime-kuma/tls/server.crt
        - /etc/uptime-kuma/tls/server.key
      register: uptime_kuma_protected_paths

    - name: Assert protected path ownership and modes
      ansible.builtin.assert:
        that:
          - uptime_kuma_protected_paths.results[0].stat.pw_name == 'kuma'
          - uptime_kuma_protected_paths.results[0].stat.mode == '0700'
          - uptime_kuma_protected_paths.results[1].stat.pw_name == 'root'
          - uptime_kuma_protected_paths.results[1].stat.mode == '0700'
          - uptime_kuma_protected_paths.results[2].stat.mode == '0644'
          - uptime_kuma_protected_paths.results[3].stat.gr_name == 'www-data'
          - uptime_kuma_protected_paths.results[3].stat.mode == '0640'

    - name: Create an on-demand Uptime Kuma backup
      ansible.builtin.systemd_service:
        name: uptime-kuma-backup.service
        state: started

    - name: Find Uptime Kuma backup archives
      ansible.builtin.find:
        paths: /var/backups/uptime-kuma
        patterns: 'kuma-*.db.gz'
        file_type: file
      register: uptime_kuma_backup_archives

    - name: Select newest Uptime Kuma backup
      ansible.builtin.set_fact:
        uptime_kuma_newest_backup: >-
          {{ (uptime_kuma_backup_archives.files |
              sort(attribute='mtime', reverse=true) |
              first).path }}
      no_log: true

    - name: Validate newest Uptime Kuma backup
      ansible.builtin.shell:
        cmd: |
          set -o pipefail
          temporary_database="$(mktemp)"
          trap 'rm -f "$temporary_database"' EXIT HUP INT TERM
          gzip -dc "{{ uptime_kuma_newest_backup }}" > "$temporary_database"
          test "$(sqlite3 "$temporary_database" 'PRAGMA quick_check;')" = "ok"
        executable: /bin/bash
      changed_when: false
      no_log: true
```

- [ ] **Step 4: Run all static acceptance checks**

Run:

```bash
cd ansible
ansible-playbook kuma.yaml --syntax-check
ansible-playbook verify-kuma.yaml --syntax-check
ansible-playbook roles/uptime_kuma/tests/render-config.yml
ansible-playbook roles/lego/tests/render-config.yml
ansible-lint kuma.yaml verify-kuma.yaml roles/uptime_kuma
cd ..
git diff --check
```

Expected: all commands pass without warnings promoted to errors.

- [ ] **Step 5: Commit live verification**

```bash
git add ansible/verify-kuma.yaml ansible/roles/uptime_kuma/tests/render-config.yml
git commit -m "test(kuma): verify production deployment"
```

---

### Task 6: Add the bootstrap secret and operations runbook

**Files:**
- Modify: `ansible/group_vars/all/secrets.sops.yaml`
- Modify: `README.md`

**Interfaces:**
- Consumes: Existing SOPS/age configuration and existing `gitea_smtp_*` Brevo values.
- Produces: An encrypted `uptime_kuma_admin_password` and field-by-field operator instructions for initial setup, monitors, restore, upgrade, and troubleshooting.

- [ ] **Step 1: Add the encrypted administrator password without printing it**

From the repository root, first confirm the key is absent:

```bash
! rg '^uptime_kuma_admin_password:' ansible/group_vars/all/secrets.sops.yaml
```

Then generate a JSON-encoded random value and send it to SOPS over stdin:

```bash
openssl rand -base64 48 |
  tr -d '\n' |
  python -c 'import json, sys; print(json.dumps(sys.stdin.read()))' |
  sops set --value-stdin \
    ansible/group_vars/all/secrets.sops.yaml \
    '["uptime_kuma_admin_password"]'
```

Expected: the YAML key is visible but its value remains `ENC[...]`. Do not decrypt or print the file during implementation.

- [ ] **Step 2: Document instance and deployment sequence**

Add Kuma to the README environment summary and DNS-resolution command. Add a fourth deployment stage after Gitea:

```bash
cd ansible
ansible-playbook kuma.yaml
ansible-playbook verify-kuma.yaml
ansible-playbook kuma.yaml
cd ..
```

State that the second deployment must report `changed=0` for `kuma`.

- [ ] **Step 3: Document the one-time UI setup without exposing secrets**

Document these exact settings:

- URL: `https://kuma.lab.canhdinh.com`
- Admin username: `kuma-admin`
- Admin password source: SOPS key `uptime_kuma_admin_password`
- Require administrator 2FA after first login.
- Settings > Reverse Proxy > HTTP Headers > Trust Proxy: `Yes`.
- Notification type: SMTP.
- SMTP host/port/sender/username/password sources: existing SOPS keys `gitea_smtp_host`, `gitea_smtp_port`, `gitea_smtp_from`, `gitea_smtp_user`, and `gitea_smtp_password`.
- Send and confirm Kuma's test email before attaching the notification.

Do not include decrypted values or commands that print the complete secrets file.

- [ ] **Step 4: Document the initial monitor set**

Add the `Homelab` group with 60-second heartbeats and three retries. Include the exact eight monitors from the design: Kuma HTTPS, Gitea HTTPS, PostgreSQL TCP 5432, Technitium DNS A lookup for Kuma expecting `10.205.234.102`, and ping checks for `debian-incus`, DNS, PostgreSQL, and Gitea. Attach the Brevo SMTP notification to all monitors and state Kuma cannot report its own total outage.

- [ ] **Step 5: Document backup, restore, upgrade, and troubleshooting**

Include commands to inspect both timers and journals, trigger an online backup, list root-only archives, restore only while `uptime-kuma.service` is stopped, validate a restored database with `PRAGMA quick_check`, and recover the previous release symlink. Include Nginx, Kuma, Lego, DNS, certificate, and listener diagnostics without printing private keys or the SQLite database.

- [ ] **Step 6: Validate encrypted and documentation changes**

Run:

```bash
sops --decrypt ansible/group_vars/all/secrets.sops.yaml >/dev/null
git diff --check
git diff -- ansible/group_vars/all/secrets.sops.yaml README.md
mise run security:secrets
```

Expected: SOPS authentication succeeds, only ciphertext is present in the secret diff, documentation contains no secret values, and both scanners pass.

- [ ] **Step 7: Commit the runbook and encrypted secret**

```bash
git add README.md ansible/group_vars/all/secrets.sops.yaml
git commit -m "docs(kuma): add bootstrap and operations runbook"
```

---

### Task 7: Deploy and prove idempotence

**Files:**
- No source changes expected; only fix defects proven by the focused checks in their owning files.

**Interfaces:**
- Consumes: Tasks 1 through 6 and the running `kuma` Incus container at `10.205.234.102`.
- Produces: A live private Kuma endpoint with passing verification and an idempotent Ansible deployment.

- [ ] **Step 1: Confirm prerequisites without changing the host**

Run:

```bash
getent hosts kuma.lab.canhdinh.com
ssh admin@kuma.lab.canhdinh.com true
cd ansible
ansible kuma -m ansible.builtin.ping
```

Expected: DNS returns `10.205.234.102`, SSH succeeds through the configured `admin` account, and Ansible reports `pong`.

- [ ] **Step 2: Run the complete pre-deployment gate**

Run:

```bash
ansible-playbook kuma.yaml --syntax-check
ansible-playbook verify-kuma.yaml --syntax-check
ansible-playbook roles/uptime_kuma/tests/render-config.yml
ansible-playbook roles/lego/tests/render-config.yml
ansible-lint kuma.yaml verify-kuma.yaml roles/uptime_kuma
```

Expected: all checks pass before host mutation.

- [ ] **Step 3: Deploy Uptime Kuma**

Run:

```bash
ansible-playbook kuma.yaml
```

Expected: Node.js 24, Uptime Kuma 2.5.0, Nginx, Lego, and both timers are installed; the play recap has `failed=0` and `unreachable=0`.

- [ ] **Step 4: Run live verification**

Run:

```bash
ansible-playbook verify-kuma.yaml
```

Expected: all runtime, listener, HTTPS, certificate, permission, and backup assertions pass.

- [ ] **Step 5: Prove deployment idempotence**

Run:

```bash
ansible-playbook kuma.yaml
```

Expected: the `kuma` recap reports `changed=0`, `failed=0`, and `unreachable=0`.

- [ ] **Step 6: Hand off the one-time private UI setup**

Open `https://kuma.lab.canhdinh.com` for the operator. The operator retrieves the admin and Brevo values directly through SOPS, creates the account, enables 2FA and trusted proxy headers, creates the documented monitors, and confirms the Brevo test alert. Do not request passwords or tokens through chat.

- [ ] **Step 7: Run final repository checks**

Run:

```bash
cd ..
git status --short
git --no-pager log --oneline -7
```

Expected: the worktree is clean and the Kuma contract, native installation, HTTPS runtime, backups, verification, and runbook commits are present.
