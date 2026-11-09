#!/usr/bin/env python3
"""Offline regression checks for Harbor's privacy boundary; never loads provisioning."""
import re
import subprocess
import unittest
from pathlib import Path

SOURCE = (Path(__file__).resolve().parents[1] / 'k3s/harbor.sh').read_text()


def function(name):
    return re.search(r'^' + name + r'\(\) \{.*?^\}', SOURCE, re.M | re.S).group()


class PrivacyTests(unittest.TestCase):
    def run_function(self, name, setup, argument=''):
        common = '''
set -uo pipefail
info() { :; }
warn() { :; }
err() { :; }
HARBOR_PRIVATE_PROJECTS=true
HARBOR_PRIVATE_PROJECT_NAMES=(library)
HARBOR_HOST=unused.invalid
NAMESPACE_ARGOCD=argocd
NODE_SSH_USER=root
NODE_SSH_HOST=unused.invalid
SKIP_NODE_AUTH=false
NODE_PULL_USER=pull
NODE_PULL_PASS=dummy
http_code() { printf '%s' "${1##*$'\\n'}"; }
http_body() { printf '%s' "${1%$'\\n'*}"; }
'''
        return subprocess.run(['bash', '-c', common + function(name) + '\n' + setup + '\n' + name + ' ' + argument], capture_output=True, text=True)

    def test_missing_node_credentials_fail(self):
        result = self.run_function('ensure_private_projects', '', '1')
        self.assertNotEqual(result.returncode, 0)

    def test_missing_argo_credentials_fail(self):
        result = self.run_function('ensure_private_projects', 'kubectl() { [[ "$*" == "get ns argocd" ]]; }', '0')
        self.assertNotEqual(result.returncode, 0)

    def test_failed_pull_never_reopens(self):
        setup = '''
kubectl() { return 1; }
harbor_api() { printf '{"metadata":{"public":"true"}}\\n200'; }
set_project_private() { echo private; }
node_probe_image() { echo unused.invalid/library/probe:tag; }
ssh() { return 1; }
print_node_pull_recovery() { :; }
verify_projects_private() { return 0; }
'''
        result = self.run_function('ensure_private_projects', setup, '0')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), 'private')
        self.assertNotIn('set_project_public', SOURCE)

    def test_postcondition_requires_positive_api_and_manifest_evidence(self):
        # blob = digest registry_blob_digest returns ('' = manifest body unreadable);
        # blob_anon/blob_auth = codes of the anonymous / robot blob HEAD.
        for admin_code, metadata, anon_code, manifest_code, blob, blob_anon, blob_auth, expected in [
            ('200', 'false', '401', '401', 'sha256:blob', '401', '200', 0),
            ('404', 'false', '401', '401', 'sha256:blob', '401', '200', 1),
            ('200', 'unknown', '401', '401', 'sha256:blob', '401', '200', 1),
            ('200', 'false', '000', '401', 'sha256:blob', '401', '200', 1),
            ('200', 'false', '404', '401', 'sha256:blob', '401', '200', 1),
            ('200', 'false', '200', '401', 'sha256:blob', '401', '200', 1),
            ('200', 'false', '401', '200', 'sha256:blob', '401', '200', 1),
            ('200', 'false', '401', '401', '', '401', '200', 1),
            ('200', 'false', '401', '401', 'sha256:blob', '200', '200', 1),
            ('200', 'false', '401', '401', 'sha256:blob', '401', '401', 1),
            ('200', 'false', '401', '401', 'sha256:blob', '401', '404', 1),
        ]:
            with self.subTest(admin=admin_code, metadata=metadata, anonymous=anon_code, manifest=manifest_code,
                              blob=blob, blob_anon=blob_anon, blob_auth=blob_auth):
                setup = f'''
harbor_api() {{ printf '{{"metadata":{{"public":"{metadata}"}}}}\\n{admin_code}'; }}
curl() {{ echo {anon_code}; }}
project_sample_artifact() {{ echo 'library/probe sha256:example'; }}
registry_manifest_code() {{ if [[ $# == 2 ]]; then echo {manifest_code}; else echo 200; fi; }}
registry_blob_digest() {{ echo '{blob}'; }}
registry_head_code() {{ if [[ $# == 3 ]]; then echo {blob_anon}; else echo {blob_auth}; fi; }}
'''
                self.assertEqual(self.run_function('verify_projects_private', setup).returncode, expected)

    def test_proxy_fallback_tag_accepts_uncached_blob_only_for_the_robot(self):
        # A proxy-cache project lists no artifacts: the probe uses the tag "latest". The robot may
        # get 404 for an uncached blob (authorised, not cached); anonymous must still get 401.
        for blob_anon, blob_auth, expected in [('401', '404', 0), ('401', '200', 0), ('404', '404', 1), ('200', '404', 1)]:
            with self.subTest(blob_anon=blob_anon, blob_auth=blob_auth):
                setup = f'''
harbor_api() {{ printf '{{"metadata":{{"public":"false"}}}}\\n200'; }}
curl() {{ echo 401; }}
project_sample_artifact() {{ echo 'dockerhub-proxy/library/probe latest'; }}
registry_manifest_code() {{ if [[ $# == 2 ]]; then echo 401; else echo 200; fi; }}
registry_blob_digest() {{ echo 'sha256:blob'; }}
registry_head_code() {{ if [[ $# == 3 ]]; then echo {blob_anon}; else echo {blob_auth}; fi; }}
'''
                self.assertEqual(self.run_function('verify_projects_private', setup).returncode, expected)

    def test_probe_images_are_strict_references_on_the_server_node(self):
        digest = 'sha256:' + 'a' * 64
        pods = {'items': [
            {'spec': {'nodeName': 'srv', 'containers': [{'image': 'unused.invalid/library/app:1@' + digest}]}},
            {'spec': {'nodeName': 'srv', 'containers': [{'image': 'unused.invalid/library/tagged:2'}]}},
            {'spec': {'nodeName': 'srv', 'containers': [{'image': "unused.invalid/library/x';touch /pwned;'@" + digest}]}},
            {'spec': {'nodeName': 'srv', 'containers': [{'image': 'unused.invalid/library/y$(id)'}]}},
            {'spec': {'nodeName': 'gpu', 'containers': [{'image': 'unused.invalid/library/huge@' + digest}]}},
            {'spec': {'nodeName': 'srv', 'containers': [{'image': 'docker.io/library/nginx:1'}]}},
        ]}
        import json
        import tempfile
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as fixture:
            json.dump(pods, fixture)
        self.addCleanup(Path(fixture.name).unlink)
        setup = f'''
kubectl() {{
  case "$*" in
    *control-plane*) echo srv ;;
    "get pods -A -o json") cat {fixture.name} ;;
  esac
}}
'''
        result = self.run_function('node_probe_images', setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ['unused.invalid/library/app:1@' + digest, 'unused.invalid/library/tagged:2'])

    def test_unlisted_nodes_fail_closed(self):
        body = function('ensure_node_registry_auth')
        self.assertIn('Cannot list the nodes', body)
        agents = re.search(r'  local agents nodes_json\n.*?\n  fi\n', body, re.S).group()
        result = subprocess.run(['bash', '-c', 'err() { :; }\nkubectl() { return 1; }\nf() {\n' + agents + 'return 0\n}\nf'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)

    def test_empty_project_is_still_probed(self):
        setup = 'harbor_api() { printf "[]\\n200"; }'
        result = self.run_function('project_sample_artifact', setup, 'dockerhub-proxy')
        self.assertEqual(result.stdout.strip(), 'dockerhub-proxy/library/hello-world latest')

    def test_argocd_chart_credential_must_match_and_be_accepted(self):
        for ns, user, pass_, valid, expected in [
            (False, '', '', 1, 0),            # no ArgoCD: nothing to check
            (True, 'pull', 'dummy', 0, 0),    # same robot, Harbor accepts it
            (True, 'pull', 'stale', 0, 1),    # stale password
            (True, '', '', 0, 1),             # Secret missing
            (True, 'pull', 'dummy', 1, 1),    # Harbor refuses it
        ]:
            with self.subTest(ns=ns, user=user, password=pass_, valid=valid):
                setup = f'''
NAMESPACE_HARBOR=harbor
NODE_PULL_SECRET=harbor-node-pull
kubectl() {{
  case "$*" in
    "get ns argocd") return {0 if ns else 1} ;;
    *username*) printf '%s' '{user}' | base64 ;;
    *password*) printf '%s' '{pass_}' | base64 ;;
  esac
}}
pull_credential_valid() {{ return {valid}; }}
'''
                self.assertEqual(self.run_function('verify_argocd_chart_credential', setup).returncode, expected)

    def test_existing_robot_is_never_automatically_rotated(self):
        body = function('ensure_node_pull_credentials')
        self.assertNotIn('harbor_api PATCH', body)
        self.assertIn('rotation requires an explicit owner procedure', body)


if __name__ == '__main__':
    unittest.main()
