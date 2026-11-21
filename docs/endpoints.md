# MAOS migrated endpoints — liveness checklist

MAOS repoints several platform services from Google/GrapheneOS endpoints to
maproj.org infrastructure (see the patches under `../patches/`). The OS-side
configuration is in-tree; whether the **servers** actually exist and behave is
asserted in patch comments and commit messages, not evidenced anywhere. This
file is the evidence checklist: run the probes before a publish, and record
the date + result here. Until a row says otherwise, treat it as unverified.

**Status of every row below: UNVERIFIED** (no probe results recorded yet —
do not read a row's presence here as proof the service is up).

| # | Service | Endpoint the OS uses | In-repo evidence (config only) | Probe | Last verified |
|---|---------|----------------------|--------------------------------|-------|---------------|
| 1 | SUPL (assisted GNSS) | `supl.maproj.org:7275` (TLS) | `patches/frameworks_base_gnss_servers.patch` (comment says a TLS proxy "will run" there); `settings.patch` removes the standard SUPL mode, so if this is down the only fallback is Off | `openssl s_client -connect supl.maproj.org:7275 -brief </dev/null` — expect a TLS handshake, not a reset/timeout | UNVERIFIED |
| 2 | PSDS (predicted satellite data) | `https://static.maproj.org/psds/<type>…` | `patches/frameworks_base_gnss_servers.patch` assumes the mirror layout `psds/<type><original path>`; standard PSDS mode removed in Settings | `curl -sS -o /dev/null -w '%{http_code}\n' https://static.maproj.org/psds/broadcom/` (adjust `<type>`/path per device logs) — expect 200 on a real file, not the SPA/index fallback | UNVERIFIED |
| 3 | Private DNS probe (wildcard DNS) | `*-dnsotls-ds.dnscheck.maproj.org` | `patches/networkstack_private_dns_probe.patch` requires a wildcard A/AAAA record for `dnscheck.maproj.org` | `dig +short random123-dnsotls-ds.dnscheck.maproj.org` (any random label) — expect an answer for arbitrary labels | UNVERIFIED |
| 4 | Captive portal / connectivity check | `https://maproj.org/generate_204` | `patches/networkstack_captive_portal.patch`; RRO `config_httpsTimeUrls` also points here | `curl -sS -o /dev/null -w '%{http_code}\n' https://maproj.org/generate_204` — expect 204 with an empty body | UNVERIFIED |
| 5 | Certificate Transparency log list | `https://static.maproj.org/android/certificate_transparency/` | `patches/packages_modules_Connectivity_certificate_transparency.patch` | `curl -sSI https://static.maproj.org/android/certificate_transparency/log_list.json` (confirm the exact path against the patch) — expect 200 | UNVERIFIED |
| 6 | Remote Key Provisioning | `https://rkp.maproj.org/v1…` (proxy → Google upstream) | `patches/frameworks_base_remote_key_provisioning.patch` | `curl -sS -o /dev/null -w '%{http_code}\n' https://rkp.maproj.org/` — expect an RKP-path response (4xx on a bare path is fine; connection failure is not); full check needs a device attestation fetch | UNVERIFIED |
| 7 | Widevine provisioning | `https://wv.maproj.org…` (proxy → googleapis upstream) | `patches/frameworks_base_widevine_provisioning.patch` | `curl -sS -o /dev/null -w '%{http_code}\n' https://wv.maproj.org/` — expect a service response, not a connection failure; full check needs a device provisioning request | UNVERIFIED |
| 8 | Device attestation | `https://api.maproj.org/attest/v1…` | `patches/packages_apps_Settings_maos_attestation.patch`; one-shot, user-triggered | `curl -sS -o /dev/null -w '%{http_code}\n' https://api.maproj.org/attest/v1` — expect an API response (4xx on a bare GET is fine); full check is the Settings Verify flow on a device | UNVERIFIED |
| 9 | OTA metadata | `https://ota.maproj.org/<device>-stable` | `maos_branding.mk` (`ro.maos.ota.server`); `build-maos.sh` publish phase | `curl -sS https://ota.maproj.org/cheetah-stable` — expect the current build's metadata line after a publish | UNVERIFIED |

## How to record a verification

Replace the row's `UNVERIFIED` with `YYYY-MM-DD — <result>` (e.g.
`2026-11-21 — 204 OK`). If a probe fails, leave the failure text in the cell —
a recorded failure is more useful than a silent pass. Re-run the whole table
before each publish; rows 1–3 are ship-blocking because Settings offers no
standard-mode fallback for SUPL/PSDS, and Private DNS validation depends on
the wildcard record.
