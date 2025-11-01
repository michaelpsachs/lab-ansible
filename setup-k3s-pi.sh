#!/bin/bash
set -e

BASE_DIR=~/lab-ansible/k3s-cluster
mkdir -p $BASE_DIR/{playbooks,group_vars,host_vars,roles/{k3s-master,k3s-worker,awx,common}/{tasks,vars,templates,files,handlers},files,templates}

echo "[INFO] Setting up K3s Ansible structure on Pi at $BASE_DIR..."

# ────────────────────────────────
# Ansible config
# ────────────────────────────────
cat > $BASE_DIR/ansible.cfg <<'EOF'
[defaults]
inventory = ./inventory.ini
roles_path = ./roles
host_key_checking = False
retry_files_enabled = False
deprecation_warnings = False
timeout = 30
EOF

# ────────────────────────────────
# Static inventory for K3s network
# ────────────────────────────────
cat > $BASE_DIR/inventory.ini <<'EOF'
[k3s-master]
172.20.0.10 ansible_user=mike

[k3s-workers]
172.20.0.11 ansible_user=mike
172.20.0.12 ansible_user=mike

[all:vars]
ansible_python_interpreter=/usr/bin/python3
k3s_token_file=/tmp/k3s_token.txt
EOF

# ────────────────────────────────
# Global vars
# ────────────────────────────────
cat > $BASE_DIR/group_vars/all.yml <<'EOF'
k3s_version: v1.30.0+k3s1
awx_namespace: awx
awx_version: latest
node_user: mike
EOF

# ────────────────────────────────
# Site playbook (entry point)
# ────────────────────────────────
cat > $BASE_DIR/site.yml <<'EOF'
---
- import_playbook: playbooks/k3s-install.yml
- import_playbook: playbooks/awx-deploy.yml
EOF

# ────────────────────────────────
# Playbook: Install K3s
# ────────────────────────────────
cat > $BASE_DIR/playbooks/k3s-install.yml <<'EOF'
---
- name: Install K3s master and workers
  hosts: all
  become: yes
  roles:
    - { role: k3s-master, when: "'k3s-master' in group_names" }
    - { role: k3s-worker, when: "'k3s-workers' in group_names" }
EOF

# ────────────────────────────────
# Playbook: Deploy AWX
# ────────────────────────────────
cat > $BASE_DIR/playbooks/awx-deploy.yml <<'EOF'
---
- name: Deploy AWX on K3s
  hosts: k3s-master
  become: yes
  roles:
    - awx
EOF

# ────────────────────────────────
# Role: k3s-master
# ────────────────────────────────
cat > $BASE_DIR/roles/k3s-master/tasks/main.yml <<'EOF'
- name: Install K3s master
  shell: |
    curl -sfL https://get.k3s.io | sh -s - server --node-ip={{ ansible_host }} --tls-san={{ ansible_host }}
  args:
    creates: /usr/local/bin/k3s

- name: Get K3s token
  shell: cat /var/lib/rancher/k3s/server/node-token
  register: token

- name: Save token for workers
  delegate_to: localhost
  copy:
    content: "{{ token.stdout }}"
    dest: "{{ k3s_token_file }}"
EOF

# ────────────────────────────────
# Role: k3s-worker
# ────────────────────────────────
cat > $BASE_DIR/roles/k3s-worker/tasks/main.yml <<'EOF'
- name: Read K3s token
  delegate_to: localhost
  slurp:
    src: "{{ k3s_token_file }}"
  register: k3s_token_local

- set_fact:
    k3s_token: "{{ k3s_token_local.content | b64decode | trim }}"

- name: Install K3s worker
  shell: |
    curl -sfL https://get.k3s.io | \
      K3S_URL=https://172.20.0.10:6443 \
      K3S_TOKEN={{ k3s_token }} sh -
  args:
    creates: /usr/local/bin/k3s-agent
EOF

# ────────────────────────────────
# Role: awx
# ────────────────────────────────
cat > $BASE_DIR/roles/awx/tasks/main.yml <<'EOF'
- name: Create AWX namespace
  shell: kubectl create namespace {{ awx_namespace }} --dry-run=client -o yaml | kubectl apply -f -

- name: Install AWX Operator
  shell: kubectl apply -f https://github.com/ansible/awx-operator/releases/{{ awx_version }}/download/awx-operator.yaml

- name: Deploy AWX instance
  copy:
    dest: /tmp/awx.yaml
    content: |
      apiVersion: awx.ansible.com/v1beta1
      kind: AWX
      metadata:
        name: awx
        namespace: {{ awx_namespace }}
      spec:
        service_type: NodePort
        nodeport_port: 30080

- name: Apply AWX manifest
  shell: kubectl apply -f /tmp/awx.yaml
EOF

echo "[SUCCESS] ✅ K3s Ansible structure created at: $BASE_DIR"
echo
echo "Next steps:"
echo "  cd $BASE_DIR"
echo "  ansible-playbook site.yml"
echo
echo "Your K3s nodes should be reachable via:"
echo "    172.20.0.10 (master)"
echo "    172.20.0.11 (worker1)"
echo "    172.20.0.12 (worker2)"
echo
echo "Ensure your Pi’s SSH key (~/.ssh/id_ed25519.pub) is on those VMs."
