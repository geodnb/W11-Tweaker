# W11 Tweaker

A single-file PowerShell tool with a proper window for turning Windows 11 optimisations on and off — with every original setting saved first, so anything it changes can be put back.

Each tweak is labelled honestly by how much evidence there is behind it, from "Recommended" down to "Unproven", and the risky ones say exactly what they trade away.

## Features

- **71 tweaks** across gaming and graphics, power, CPU and timers, security trade-offs, privacy and AI, background apps and updates, input, network, storage, and desktop.
- **Evidence-based tiers.** Every tweak is tagged:
  - **Recommended** — measurable benefit or clear consensus, low downside.
  - **Situational** — helps in specific cases; read the trade-off.
  - **Unproven** — popular, but testing shows little or no effect on modern Windows. Included so you can try it yourself.
  - **Security** — gains performance by reducing protection (for example Memory Integrity / VBS).
  - **Risky** — can break things (for example stopping the hypervisor breaks WSL2 and Docker).
- **Snapshot and restore.** Before changing anything, the tool records the original value. Untick a tweak to put your original back, or press **Restore everything**.
- **Explains every tweak.** Each one shows what it does, what the evidence says, any warnings, the exact registry, power or boot setting it touches, its current value and your saved original.
- **Reads the real state.** For example, hardware-accelerated GPU scheduling is checked with the graphics driver, and the status strip shows whether VBS and Memory Integrity are actually running.
- **Applies instantly where possible.** Mouse, keyboard and accessibility tweaks take effect without signing out.
- **Quiet by design.** Routine changes apply with no pop-ups; you're only asked to confirm risky or one-way changes.

## Safety

- Offers a **Windows restore point** before the first change in a session.
- **Never turns security features on or off behind your back.** Reverting only restores the exact value it saved; it won't re-enable Memory Integrity without Windows Security's driver check.
- If a setting was already that way before you used the tool, reverting leaves it alone.
- **BitLocker aware.** Offers to suspend BitLocker for one restart before boot-time security changes, refuses to stop the hypervisor when VBS is set to Mandatory, and skips VBS changes that are UEFI-locked.
- Its data folder (`%ProgramData%\W11Tweaker`) is locked to Administrators and SYSTEM, and every saved value is validated before it's written back.
- Two tweaks (app removals) are one-way and clearly marked; reinstall those apps from the Microsoft Store.

Deliberately **not** included: turning off Defender, UAC, Smart App Control (can't be re-enabled without reinstalling Windows), disabling Windows Update, removing the page file, and GPU driver settings.

## Requirements

- Windows 11 (built and checked against 24H2/25H2)
- Windows PowerShell 5.1 (built in)
- An administrator account

## Usage

1. Download `W11Tweaker.ps1` and `Run W11 Tweaker.cmd` into the same folder.
2. Double-click **Run W11 Tweaker.cmd** and approve the admin prompt.
3. Tick or untick tweaks, then press **Apply**. The status line tells you if a restart, sign-out or Explorer restart is needed.

Logs and the snapshot live in `%ProgramData%\W11Tweaker`.

For best security, keep the tool in a folder only administrators can write to (for example `C:\Program Files\W11Tweaker`) rather than Downloads.

## Licence

This project is **not released under an open-source licence**. All rights reserved.

You're welcome to download and run W11 Tweaker on your own PCs and to read the code. Please don't redistribute or republish it, modified or unmodified, without permission.

## Disclaimer

**Use this tool entirely at your own risk.**

W11 Tweaker changes Windows system settings, including registry values, power plans, services, boot configuration and security features. Although it saves your original settings and offers a restore point, changes like these can have unintended effects depending on your hardware, drivers, Windows version, other software and existing configuration.

This software is provided **"as is", without warranty of any kind**, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose and non-infringement. The author and contributors **accept no responsibility or liability** for any damage, data loss, system instability, failure to boot, security compromise, loss of warranty, lost time or any other loss or harm, direct or indirect, arising from the use or misuse of this tool, even if advised of the possibility of such damage.

In particular:

- **Security and Risky tweaks reduce protection or can break features.** Read each warning, and only apply them if you understand and accept the trade-off.
- **The snapshot and restore features are a best effort, not a guarantee.** Some changes (such as removed apps) can't be undone automatically, and Windows updates, other tools or hardware changes can interfere with restoring.
- **Back up your important data and keep your BitLocker recovery key safe** before making changes.
- Nothing here is professional advice. Descriptions and evidence notes reflect publicly available information at the time of writing and may become outdated as Windows changes.
- This project is not affiliated with, endorsed by or supported by Microsoft. Windows is a trademark of Microsoft Corporation.

By downloading or running this tool, you accept full responsibility for its use and any consequences.
