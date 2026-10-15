# Incident Report: ekycstaging Server Reboots

## 1. Issue Summary
The `ekycstaging` server (IP: 192.168.40.31) experienced recurring, unexpected reboots over a three-day period (Sept 22, Sept 23, and Sept 24). The server crashed abruptly, causing standard system logs to stop without recording shutdown signals. 

## 2. Environment Impact
*   **Affected Server:** `ekycstaging` only. 
*   **Unaffected Servers:** All other dev, UAT, and staging servers are stable and unaffected.
*   **Workloads:** Docker containers running Nginx, MySQL, Kafka, and Redis.
*   **Operating System:** Ubuntu Server (VMware virtual machine).

## 3. Root Cause Analysis
The crashes were caused by a **Null Pointer Dereference** (memory access violation) inside the kernel's task scheduler. 

*   **The Flaw:** The server was running a specialized "real-time" kernel (`6.8.1-1015-realt`) instead of the standard Ubuntu generic kernel. 
*   **The Trigger:** Under Docker network workloads, when network polling functions (`epoll_wait`) transitioned to an idle state (putting the CPU to sleep), a bug in the real-time scheduler (`pick_next_task_fair`) attempted to read a blank/invalid memory address. 
*   **The Result:** To prevent data corruption from the invalid memory access, the operating system intentionally triggered a Kernel Panic, instantly shutting down and forcing a hardware-level reboot. 
*   **Origin:** The `realtime-kernel` was not installed via Ubuntu Pro. It was inadvertently selected during the initial bare-metal OS installation.

## 4. Resolution Steps
The issue is resolved by removing the unstable real-time kernel and replacing it with the highly stable standard generic kernel.

Execute the following commands as `root` on `ekycstaging`:

**Step 1: Install the generic kernel packages**
```bash
apt update
apt install linux-generic linux-image-generic linux-headers-generic -y
```

**Step 2: Purge the real-time kernel**

```Bash
apt remove --purge *realtime* -y
apt autoremove --purge -y
```
(Note: When prompted with the pink "Abort kernel removal?" warning screen, select < No > to proceed).

**Step 3: Update the bootloader and reboot**

```Bash
update-grub
reboot
```

## 5. Verification
After the server reboots, run uname -r. The output should now display -generic instead of -realt, confirming the stable kernel is active and the memory crashes are permanently resolved.

## 6. Diagnostic Commands & Error Traces
The following commands and outputs were used to isolate the root cause:

**A. Identifying the Crash Times & Kernel Version**

```Bash
last reboot | head -n 5
```
Key Finding: Confirmed daily reboots at specific times (e.g., 04:10, 09:40) and revealed the abnormal kernel string 6.8.1-1015-realt (truncated).

**B. Confirming a Hard Crash (Kernel Panic)**

```Bash
journalctl -b -1 -e
```
Key Finding: Standard logs abruptly ceased 24 minutes prior to the 09:40 reboot. The absence of shutdown signals indicated a sudden kernel-level failure rather than a graceful restart.

**C. Locating the Crash Dumps**

```Bash
ls -lh /var/crash/
```
Key Finding: Found directories (202609221659, 202609230410) matching exact crash times, confirming the kdump mechanism was catching recurring kernel panics.

**D. Extracting the Smoking Gun (Memory Violation)**

```Bash
cat /var/crash/202609230410/dmesg.202609230410 | tail -n 50
```
Key Error Trace:

CR2: 0000000000000098 (The CPU attempting to read a null/invalid memory address).

The stack trace showed this occurred during container network polling (epoll_wait -> do_epoll_wait) as the CPU scheduler attempted to fetch the next background task (__schedule -> pick_next_task_fair).

**E. Ruling out Ubuntu Pro Configuration**

```Bash
pro status
```
Key Finding: Returned realtime-kernel yes disabled, proving the faulty kernel was not being actively enforced by the Ubuntu Pro management agent, pointing to an installation-time error.