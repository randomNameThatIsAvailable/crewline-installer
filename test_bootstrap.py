"""Local source-contract checks; these do not install anything or prove VPS success."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent


class BootstrapContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "install.sh").read_text(encoding="utf-8")
        cls.entry = (ROOT / "entry.sh").read_text(encoding="utf-8")

    def test_firewall_precedes_service_installation(self):
        self.assertLess(self.source.index("ufw --force enable"), self.source.index("install_docker()"))
        self.assertLess(self.source.index("ufw --force enable"), self.source.index("    nginx \\\n"))
        self.assertLess(self.source.index('ufw allow "$port/tcp"'), self.source.index("ufw --force enable"))
        self.assertIn("sshd -T", self.source)
        self.assertIn("IPV6=yes", self.source)
        self.assertNotIn("ufw reset", self.source)

    def test_pinned_recovery_and_separate_locks(self):
        self.assertIn('releases/tags/$release_tag', self.source)
        self.assertIn('cmp --silent "$manifest_path" "$recovery_directory/release.env"', self.source)
        self.assertIn('cmp --silent "$checksum_path" "$recovery_directory/archive.sha256"', self.source)
        self.assertIn("/run/crewline-bootstrap.lock", self.source)
        self.assertIn("flock --nonblock 8", self.source)
        self.assertIn('exec 9>>"$project_directory/.crewline-deploy.lock"', self.source)
        self.assertLess(self.source.index('flock --nonblock 9'), self.source.index('cp -a'))
        self.assertIn('"$domain" --resume --bootstrap-lock-held', self.source)
        self.assertIn('CREWLINE_BOOTSTRAP_CONTRACT', self.source)

    def test_recovery_pin_follows_all_archive_validation(self):
        commit = self.source.index('mv -T -- "$pending_pin" "$pin_directory"')
        self.assertLess(self.source.index('sha256sum --check --strict "$checksum_name"'), commit)
        self.assertLess(self.source.index('python3 -B "$staging/docker/deployment_contract.py" archive'), commit)
        for name in ('release.env', 'archive.sha256', 'target'):
            self.assertLess(self.source.index(f'"$pending_pin/{name}"'), commit)
        self.assertLess(commit, self.source.index('cp -a'))
        self.assertIn('recovery_directory="$bootstrap_directory"', self.source)
        self.assertIn('recovery_directory="$pin_directory"', self.source)

    def test_recovery_refuses_changed_installer_or_deployed_release(self):
        self.assertIn('"$(<"$bootstrap_directory/installer.sha256")" == "$installer_sha256"', self.source)
        self.assertLess(self.source.index('cmp --silent "$manifest_path" "$deployment_record"'), self.source.index('cp -a'))

    def test_interruption_handlers_and_atomic_nginx_writes(self):
        for source in (self.source, self.entry):
            for signal, code in (('INT', 130), ('TERM', 143), ('HUP', 129)):
                self.assertIn(f"trap 'exit {code}' {signal}", source)
        self.assertIn('mv -T -- "$nginx_pending" "$site"', self.source)
        self.assertIn('mv -T -- "$hook_pending" "$hook"', self.source)

    def test_public_entry_validates_before_execution(self):
        self.assertIn('^[0-9a-f]{40}$', self.entry)
        self.assertIn('^[0-9a-f]{64}$', self.entry)
        self.assertLess(self.entry.index('sha256sum --check'), self.entry.index('bash "$temporary_directory/install.sh"'))
        self.assertNotIn('/main/install.sh', self.entry)
        self.assertIn('-t 0 && -t 1', self.entry)

    def test_acme_rollback_remains_armed_until_https_activation(self):
        start = self.source.index('nginx_site_changed=true')
        activate = self.source.index('bash "$project_directory/enable-https.sh"')
        disarm = self.source.index('nginx_site_changed=false', start)
        self.assertLess(self.source.index('certbot certonly --webroot', start), activate)
        self.assertLess(activate, disarm)

    def test_checksum_parser_does_not_strip_extra_lines(self):
        start = self.source.index('python3 - "$checksum_name" "$archive_name"')
        body = self.source[start:self.source.index('\nPY', start)]
        self.assertIn('read_text(encoding="ascii")', body)
        self.assertNotIn('.strip()', body)

    def test_host_tls_uses_webroot_and_reports_private_phase_separately(self):
        self.assertIn('certbot certonly --webroot', self.source)
        self.assertNotIn('--standalone', self.source)
        self.assertNotIn('--agree-tos', self.source)
        self.assertIn('systemctl enable --now certbot.timer', self.source)
        self.assertIn('checkpoint crewline-https-ready', self.source)
        self.assertLess(self.source.index('checkpoint crewline-https-ready'), self.source.index('checkpoint private-access-ready'))
        self.assertIn('Not verified here: access from your phone/another tailnet device', self.source)

    def test_private_panel_is_pinned_and_configured_before_startup(self):
        self.assertIn('VERSION = "v3.9.0"', self.source)
        self.assertIn('d7cbe0bf6358ee0d2117c24fd2efb483502e411d38e2ea59bd0bf5e7a3e39390', self.source)
        self.assertIn('"webListen": "127.0.0.1"', self.source)
        self.assertIn('"subEnable": "false"', self.source)
        self.assertLess(self.source.index('"$private_helper" database'), self.source.index('systemctl enable --now x-ui.service'))
        self.assertIn('bcrypt.hashpw(credentials["password"].encode()', self.source)
        self.assertNotIn('-password "', self.source)

    def test_private_serve_is_bounded_persistent_and_preserves_other_configuration(self):
        self.assertIn('timeout --foreground 180 tailscale up --timeout=170s', self.source)
        self.assertIn('timeout --foreground 180 tailscale serve --bg --https=9443 http://127.0.0.1:2053', self.source)
        self.assertIn('unrelated(original) != unrelated(current)', self.source)
        self.assertIn('config.get("AllowFunnel")', self.source)
        self.assertNotIn('tailscale serve reset', self.source)
        self.assertNotIn('ufw allow 2053', self.source)
        self.assertNotIn('ufw allow 9443', self.source)

    def test_panel_credentials_are_saved_before_installation_and_not_reset_on_recovery(self):
        self.assertIn('pending / name', self.source)
        self.assertIn('os.chmod(path, 0o600)', self.source)
        self.assertIn('os.rename(pending, STATE)', self.source)
        self.assertIn('if fresh:\n            settings["webBasePath"]', self.source)
        self.assertIn('recovery will not expose or reset them', self.source)
        self.assertIn('initial-panel.json (root-only; values are not printed)', self.source)

    def test_checkpoint_writes_atomically_without_secret_values(self):
        body = re.search(r'checkpoint\(\) \{\n(.*?)\n\}', self.source, re.S).group(1)
        self.assertIn('mktemp "$bootstrap_directory/progress.XXXXXX"', body)
        self.assertIn('mv -T --', body)
        self.assertNotIn('token', body)
        self.assertNotIn('password', body)


if __name__ == "__main__":
    unittest.main()
