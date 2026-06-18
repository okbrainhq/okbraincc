# iPhone USB Internet Failover Verification Report

Date: 2026-06-18 13:43 Asia/Colombo
Host project: okbraincc

## Summary

It is possible to programmatically disable and re-enable the `iPhone USB` network service on this Mac. When `iPhone USB` is disabled, macOS immediately falls back to Wi-Fi. When `iPhone USB` is re-enabled, macOS eventually promotes it back to the default route because it is first in the network service order.

This behavior is suitable for an app-level watchdog that temporarily disables a bad iPhone USB tether when internet health is poor, lets macOS use Wi-Fi, and later re-enables the iPhone service.

## Current Mac Network Setup Observed

Network service order at test time:

1. `iPhone USB` — hardware port `iPhone USB`, device `en6`
2. `T-1` — device `usbmodem11401`
3. `USB JTAG/serial debug unit 2` — device `usbmodem112201`
4. `USB JTAG/serial debug unit` — device `usbmodem101`
5. `USB 10/100/1000 LAN` — device `en5`
6. `Thunderbolt Bridge` — device `bridge0`
7. `Wi-Fi` — device `en0`

Important active interfaces:

- `iPhone USB`: `en6`, IP `172.20.10.6`, router `172.20.10.1`
- `Wi-Fi`: `en0`, IP `192.168.8.70`, router `192.168.8.1`

Initial default route before disabling:

```text
gateway: 172.20.10.1
interface: en6
```

So the iPhone was confirmed to be the default internet path.

## Commands Verified

Disable iPhone USB service:

```bash
/usr/sbin/networksetup -setnetworkserviceenabled "iPhone USB" off
```

Re-enable iPhone USB service:

```bash
/usr/sbin/networksetup -setnetworkserviceenabled "iPhone USB" on
```

Check whether service is enabled:

```bash
/usr/sbin/networksetup -getnetworkserviceenabled "iPhone USB"
```

Check service order:

```bash
/usr/sbin/networksetup -listnetworkserviceorder
```

Check current default route:

```bash
route -n get default
```

Check active network interfaces used by macOS:

```bash
scutil --nwi
```

Check iPhone service DHCP/IP info:

```bash
networksetup -getinfo "iPhone USB"
```

## Test Results

### 1. Disable test

After running:

```bash
/usr/sbin/networksetup -setnetworkserviceenabled "iPhone USB" off
```

macOS marked the service disabled:

```text
*iPhone USB
```

The default route moved to Wi-Fi within about 8 seconds:

```text
gateway: 192.168.8.1
interface: en0
```

HTTP connectivity still worked over Wi-Fi:

```text
https://www.apple.com/library/test/success.html -> http=200 total=0.613828
https://captive.apple.com/hotspot-detect.html -> http=200 total=1.861035
https://example.com/ -> http=200 total=0.260178
```

Conclusion: disabling `iPhone USB` successfully forces macOS to use Wi-Fi.

### 2. Re-enable test

After running:

```bash
/usr/sbin/networksetup -setnetworkserviceenabled "iPhone USB" on
```

The service was enabled immediately, but the interface did not become active instantly.

Observed timing:

- At about 44 seconds after re-enable: `en6` still inactive, default route remained Wi-Fi.
- At about 84 seconds after re-enable: `en6` got DHCP again and default route returned to iPhone USB.

Final verified state:

```text
iPhone enabled state: Enabled
IP address: 172.20.10.6
Router: 172.20.10.1
default gateway: 172.20.10.1
default interface: en6
```

Conclusion: re-enabling works, but the app must allow a 1–2 minute recovery window before expecting iPhone USB to become the default route again.

## Important Observation

`networksetup -renewdhcp "iPhone USB"` was tried, but on this macOS environment it printed the `networksetup` usage/help output instead of renewing DHCP. Do not rely on `networksetup -renewdhcp` for this integration.

Recommended approach: after re-enabling, poll `networksetup -getinfo "iPhone USB"`, `ifconfig <device>`, `scutil --nwi`, and `route -n get default` until the interface receives an IP and becomes the default route again.

## Recommended Integration Design

### Detection

The app should not hardcode `en6`. Detect it dynamically:

1. Run `networksetup -listnetworkserviceorder`.
2. Find the service named `iPhone USB`.
3. Parse the device from the line like:

```text
(Hardware Port: iPhone USB, Device: en6)
```

4. Find fallback service/device, normally `Wi-Fi` / `en0`.
5. Confirm fallback is usable before disabling iPhone USB.

### Health Checks

Avoid full speed tests because they waste mobile data. Use small checks:

- DNS resolution check.
- HTTPS request to small endpoints.
- Measure connect time, total time, HTTP status.
- Optional tiny download only, not a full bandwidth test.

Suggested endpoints:

- `https://www.apple.com/library/test/success.html`
- `https://captive.apple.com/hotspot-detect.html`
- `https://example.com/`

Suggested failure rules:

- Timeout above 5–10 seconds.
- HTTP request fails for multiple endpoints.
- 3 consecutive failed checks.
- Or sustained very low small-download throughput.

Suggested check interval:

- Every 15–30 seconds when healthy.
- Faster, e.g. every 5–10 seconds, only while in suspected-failure state.

### State Machine

Recommended states:

```text
HealthyOnIPhone
SuspectIPhoneSlow
FailoverPending
IPhoneDisabledUsingWifi
CooldownBeforeRestore
ReenableIPhone
ValidateIPhoneRestored
BackOnIPhone
```

Transition idea:

1. Start in `HealthyOnIPhone` when default route is iPhone USB.
2. If health checks fail repeatedly, enter `SuspectIPhoneSlow`.
3. If fallback Wi-Fi is active and healthy, schedule an auto-restore guard, then disable `iPhone USB`.
4. Confirm route switches to Wi-Fi.
5. Stay on Wi-Fi for a cooldown, e.g. 2–5 minutes.
6. Re-enable `iPhone USB`.
7. Poll for up to 2 minutes for DHCP/default route to return.
8. Validate health on iPhone path before declaring recovered.
9. If iPhone still fails, disable again and use a longer cooldown.

### Safety Rules

Before disabling `iPhone USB`:

- Confirm Wi-Fi has an IP address.
- Confirm Wi-Fi can reach at least one health endpoint.
- Schedule an automatic restore command before disabling iPhone USB.
- Add anti-flapping: minimum cooldown between toggles.
- Limit toggles per hour.
- Keep a log of every disable/re-enable action.

Auto-restore guard pattern:

```bash
nohup /bin/sh -c 'sleep 120; /usr/sbin/networksetup -setnetworkserviceenabled "iPhone USB" on' >/tmp/okbrain-iphone-usb-auto-restore.log 2>&1 &
```

This prevents leaving the machine permanently stuck if the app crashes after disabling iPhone USB.

### Permissions

In this environment, `networksetup -setnetworkserviceenabled` worked without `sudo` from the current process. A packaged GUI app may still need elevated privileges depending on user account, macOS policy, or MDM configuration.

Integration options:

- Try direct `Process` execution first and handle permission failure.
- If permission fails, use a privileged helper / LaunchDaemon rather than prompting repeatedly.
- Never embed passwords.

### Swift App Integration Notes

The app can use `Process` to run:

- `/usr/sbin/networksetup`
- `/usr/sbin/scutil`
- `/sbin/route`
- `/sbin/ifconfig`
- `/usr/bin/curl` for diagnostics, or native `URLSession` for generic health checks.

For interface-specific tests, command-line `curl --interface <device>` may be useful, but this should be validated separately.

The UI should show:

- Current default route: `iPhone USB` or `Wi-Fi`.
- iPhone service status: enabled/disabled, active/inactive, IP/router.
- Latest health-check result.
- Last failover time.
- Cooldown remaining.
- Manual controls: `Disable iPhone USB`, `Re-enable iPhone USB`, `Run health check`.

## Caveats

- Re-enable is not instant. In the test, iPhone USB took roughly 80–90 seconds to become active/default again.
- `networksetup -renewdhcp` should not be used unless separately verified on the target macOS version.
- If Wi-Fi is not healthy, the app should not disable iPhone USB.
- If another higher-priority active network appears, macOS may choose that instead of Wi-Fi.
- The service name can change if renamed by the user, so detection should support configuration.

## Final Verdict

This is feasible.

Verified behavior on this Mac:

- `iPhone USB` was default route: `en6` via `172.20.10.1`.
- Disabling `iPhone USB` moved default route to Wi-Fi: `en0` via `192.168.8.1`.
- Internet worked while on Wi-Fi.
- Re-enabling `iPhone USB` eventually restored it as default route.

Recommended implementation: a small watchdog inside the app using health checks, a safe state machine, automatic restore guard, and careful polling after re-enable.
