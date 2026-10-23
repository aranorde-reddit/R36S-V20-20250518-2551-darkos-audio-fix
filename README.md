# R36S clone V20 2025-05-18 (batch 2551) — dArkOS audio fix

**No sound at all on dArkOS (speaker and headphones) on the R36S clone motherboard `R36S-V20 2025-05-18 2551`?** This repository contains the root cause, the evidence, and a one-click fix that also makes the audio behave properly afterwards (correct speaker/headphone switching, a usable volume scale, less headphone hiss).

**Current version: v2.2** — see [What the fix does](#what-the-fix-does) and the [changelog](#changelog).

## Quick fix (2 minutes)

1. Download **both** files from [`fix/`](fix/) — `Install Audio Fix.sh` and `Uninstall Audio Fix.sh` — or the zip from the latest [release](../../releases).
2. Put them in the `tools` folder on your ROMs partition (EASYROMS).
3. On the device: **Options → Tools → Install Audio Fix**. It shows its progress and ends with *"First install done"* (or *"Upgrade done"*). Reboot.
4. Menus, games, speaker and headphones now work. To remove everything: **Tools → Uninstall Audio Fix**, then reboot.

The same installer is used for a first install and for upgrading from any earlier version of this fix — it replaces the old version completely, nothing is left behind. The install screen is also saved as `tools/audio_fix_install.txt`.

Tested on dArkOS-G80CA-RE 10/02/2026 (kernel 4.4.189 #86, lcdyk). It should apply to any dArkOS / ArkOS4Clone build on this kernel line; if your board is a different batch and you have the same "everything looks right but nothing plays" symptom, it's worth trying — the installer checks for the RK817 chip first and changes nothing if it isn't there.

## What the fix does

One small background service (a bash script, about 1 MB of RAM, **no CPU while idle, no polling** — it sleeps until the headphone jack or the mixer changes):

| Problem on this board under dArkOS | What the fix does |
|---|---|
| **No audio at all** — the RK817 codec's audio PLL never locks (see the write-up below) | "Kicks" the codec (DAC bias down → DAC digital clock off/on → PLL power-cycle → bias on) at boot, after every headphone plug/unplug, whenever the audio path changes, and after resume. Every kick is verified and retried if needed. |
| **Headphones silent / speaker stays on** — dArkOS's hotkey daemon has the headphone-jack polarity backwards on this board, so it switches the audio path the wrong way | Switches speaker ↔ headphones itself the moment the jack changes, drives the speaker-enable line (GPIO3_A7), and undoes the hotkey daemon's wrong switch within milliseconds. |
| **Hiss in the headphones when nothing plays** | Sets the codec's headphone anti-pop stage to −15 dB (the original firmware's value). Adjustable — see [Settings](#settings). |
| **Volume only audible from ~60% on the speaker** — the on-screen % is the codec's raw 0–255 register, so the bottom half of the slider is below hearing | Adds a 0–100 % volume control called **Master** that EmulationStation and the volume keys use: 0 % = mute, 1 % = −49.5 dB … 100 % = 0 dB (the same maximum as before). The speaker is audible from about 25 %. 2 dB per key press. |
| **Menu music doesn't play** (missing link on single-card setups) | Links EmulationStation's music folder to `EASYROMS/bgmusic`. |

How the volume scale stays safe: the codec stays the one real volume control — the service turns every change of Master into the codec's own volume, so games that talk to the hardware directly follow it too. The volume can **never go up by itself**: if anything else lowers the codec, Master follows it down; nothing ever raises it except a key press or the slider. If the service isn't running, moving the volume simply does nothing.

All codec register access uses atomic SMBus transactions (the RK817 is also the CPU voltage regulator and battery gauge, so the kernel talks to it constantly — two-step reads could return the wrong register).

### Installer safety

The installer tests register access on the chip before changing anything (nothing is touched if that fails), backs up whatever is installed, installs, then verifies: service running, codec kick verified, no restart loop, headphone level applied, volume control present and driving the codec, settings saved. If any check fails it puts everything back exactly as it was by itself (or removes everything, on a first install) and saves a report as `tools/audio_fix_v22_fail.txt`. On success the backup is deleted, so only one version is ever installed.

### Settings

Two numbers at the top of `Install Audio Fix.sh` (edit, then run the installer again):

- `HP_ATT=15` — headphone level. 15 = quietest, least hiss (default) … 0 = loudest, most hiss (dArkOS's own setting). Each 3 lower = 3 dB louder headphones and 3 dB more hiss. The speaker is not affected.
- `VOL_RANGE=50` — the dB range of the on-screen volume (1 % = −49.5 dB with 50). 40 makes the low end louder, 60 quieter. Allowed 30–95.

### Good to know

- EmulationStation shows the new volume scale **after the reboot**.
- After plugging/unplugging headphones there may be up to ~0.15 s of silence while the codec is kicked.
- Moving EmulationStation's own volume slider in the first ~2 s after a plug/unplug takes effect when the switch-over finishes (the volume keys are always instant).
- The service log is in RAM: `/tmp/rk817-audio-kick.log` (gone after power-off).
- The speaker is at the hardware maximum at 100 %; there is no hidden headroom to unlock (the RK817's class-D amplifier has no gain setting).

## Project status

This was a spare-time investigation on my own unit, worked through step by step with Claude (Anthropic's AI) doing the analysis. The fix works on my device and I don't have other boards to test, so it isn't actively maintained. If you have a different batch or another dArkOS build, the diagnostic scripts and evidence are all here — please test, fork, and improve freely (MIT licence). The permanent fix for the no-audio part belongs in the kernel's `rk817_codec` driver; if a maintainer picks that up, this repository will have done its job.

## Repository layout

- `fix/` — the installer and uninstaller.
- `diagnostics/` — the eight test scripts used to find the cause, in order (`audio_diag.sh` … `audio_diag8.sh`). Run from the Tools menu; each writes a report folder next to itself.
- `evidence/` — the reports from the decisive runs (dArkOS card and the original working card).
- `dtb/` — the stock DTB (`rf3536k3ka.dtb`) and the dArkOS "Variant 1" DTB for reference.

## Changelog

- **v2.2** — Usable volume scale (Master control, 0 % = mute … 100 % = 0 dB, speaker audible from ~25 %; 2 dB per key press; can never get louder by itself). Speaker/headphone switching now near-instant (~0.15 s instead of 1–2 s): the path is set the moment the jack changes, the hotkey daemon's wrong switch is undone at once, and the codec is kicked immediately when something is already playing. Installer works for first installs and upgrades from any earlier version.
- **v2.1** — Every codec register access is one atomic SMBus transaction (fixes rare wrong reads caused by the kernel's own PMIC traffic). The kick checks that the three registers it touches end in their working state and repairs them if not. Installer: tests the chip first, backs up, verifies, restores automatically on failure.
- **v2.0** — Service rewritten in bash (about 1 MB instead of 9 MB of RAM). dArkOS runs `killall python3` after every game, which stopped the earlier Python service for a few seconds; a bash service is never hit.
- **v1.7** — The Python service ignored stop signals not sent by systemd (the `killall python3` above).
- **v1.5** — Volume keys stepped on a dB curve.
- **v1.4** — Headphone anti-pop setting from the original firmware: much less idle hiss.
- **v1.3** — The service switches speaker/headphones itself (the hotkey daemon has the jack polarity backwards on this board), drives the speaker-enable line, links the menu-music folder.
- **v1.2** — Event-driven only (jack + mixer changes, no polling); every kick verified with retries.
- **v1.0** — First release: codec PLL kick at boot, after headphone events and after resume.

---

# Full write-up

## TL;DR

- **Board:** R36S clone, motherboard ID `R36S-V20 2025-05-18` batch `2551` (RK3326, RK817 PMIC/codec). Stock DTB `rf3536k3ka.dtb`. DTB tool says "Clone Type 1 Panel 2" (ArkOS4Clone) / "clone type 3 screen 1" (Aurknix).
- **Symptom on dArkOS (G80CA-RE 10/02/2026 build, kernel 4.4.189 #86 lcdyk):** zero audio — menus, games, speaker *and* headphones — at 100% volume, even playing straight to `plughw:0,0`. The original SD card that shipped with the device (Ubuntu 19.10 ArkOS build, stock DTB, newer vendor kernel with the `rockchip,multicodecs-card`) plays fine on the same unit.
- **Root cause (measured, reproduced):** the RK817 codec's audio PLL never locks under the dArkOS 4.4 kernel on this unit. The working kernel runs the Rockchip driver routine `rk817_restart_dac_digital_clk_and_apll()` at every playback start (DAC bias down → DAC digital clock off/on → **PLL power-cycle** → bias on). The dArkOS driver never does it, so the DAC engine never starts: every register looks correct, I²S is streaming, MCLK is present, and the codec produces nothing. The codec's applied-volume readback (`0x39/0x3a`) stays at the reset value `0xff` (mute) instead of following the volume setting.
- **Proof:** replaying only the DAC-clock restart over I²C during playback → still silent. Adding the PLL power-cycle (`APLL_CFG5` bit0 down/up) → sound immediately, readback jumps to the set volume, and it stays working.
- **Fix (workaround, works):** a small systemd service that performs that sequence at boot (with a silent stream open), again after every headphone plug/unplug, and after resume. One-click installer attached (`Install Audio Fix.sh`, run from Tools). Verified: menus and Mario 64 play after reboot.
- **Proper fix:** in the dArkOS/ArkOS4Clone `rk817_codec.c`, call the DAC/APLL restart at stream start (or on path set) — it already exists in the Rockchip vendor driver.

This is **not** a DTB issue. No device-tree change can fix it on the current kernel; the DTB only matters for the speaker-enable GPIO (below).

---

## 1. Device details

| Item | Value |
|---|---|
| Motherboard ID | `R36S-V20 2025-05-18 2551` (silkscreen batch 2551) |
| SoC | Rockchip RK3326 (PX30 family), LPDDR3, Mali Bifrost |
| PMIC / codec | RK817 (chip ID regs `0xed/0xee` = `0x81/0x7a`) |
| Stock DTB | `rf3536k3ka.dtb`, 107685 bytes, MD5 `bb3c63c12338769c26209269a330d0dc`, model string "Rockchip rk3326 evb lpddr3 v12 board for linux" |
| Panel | MIPI-DSI, 4 lanes, 640×480, 30 MHz pixel clock, 153×85 mm; init sequence uses `FF 30 / FF 52 / FF 01` page selects (NovaTek NV3051/3052-style) although the compatible string says `sitronix,st7703`. Timings: hfp 46 / hsync 2 / hbp 44, vfp 16 / vsync 2 / vbp 14 |
| DTB identification tool (r36s.dpdns.org) | ArkOS4Clone → *Clone R36s → Clone Type 1 Panel 2* (panel match, MD5 differs); Aurknix → *R36S clone type 3 screen 1*; battery designCapacity 1848 / designQmax 2033 |
| Audio wiring (from stock DTB) | RK817 codec on I2S1 (`i2s@ff070000`), MCLK on GPIO2_C3, sound card `rockchip,multicodecs-card` with `spk-con-gpio = GPIO3_A7` (active high) and `hp-det-gpio = GPIO2_C6` (active high, pull-up). Class-D speaker path (no `use-ext-amplifier`) |
| Headphone detect polarity | pin **low** = unplugged, **high** = plugged (verified live). So `simple-audio-card,hp-det-gpio` flag must be `0` for this board |
| Input | `play_joystick` node: 4 ADC axes, 19 GPIO keys; volume keys on ADC |
| Other | `keros,lite` chip at I²C1 address 0x1C with an LED GPIO; SDIO Wi-Fi pwrseq + BT nodes present in stock DTB |

### The two SD cards used

**Card A — original card that came with the device (audio works):**
- Ubuntu 19.10 base, `extlinux` boot, `/boot/rf3536k3ka.dtb` (stock), `Image` 30 MB (newer Rockchip vendor kernel), `rockchip,multicodecs-card` sound card (mixer has the full 11-item `Playback Path` list and a `Headset Mic Jack` control).
- The kernel claims GPIO3_A7 as `spk-con` and drives it **high only while playing to the speaker**, low for headphones.

**Card B — dArkOS (no audio):**
- dArkOS-G80CA-RE **10/02/2026** build (project now `southoz/dArkOSRE-R36`), Debian 13 (trixie).
- `boot.ini` loads `/boot/rk3326-g80ca-linux.dtb` (92018 bytes, MD5 `23d2a41ca3312d4b13263e43705a2813`, model "R36S-V20 2025-05-18 Variant 1"), `Image` MD5 `e56286f288c8c77cb86a7cbbb62d3704`, `uInitrd` MD5 `7db4a57a37cefb9c41d6cec2b2932919`, `rg351mp-uboot.dtb` MD5 `ddf12c51886e165ab63da42233208fc7`, `rg351v-uboot.dtb` MD5 `b784e0a96c2e5829c984dcf674f9a441`.
- Kernel: `Linux 4.4.189 #86 SMP Sat Dec 27 09:09:43 CST 2025 (lcdyk@Lcdyk)` — the ArkOS4Clone kernel. U-Boot identifies as "Rockchip RK3326 RG351 Series".
- Sound card `simple-audio-card`, codec `rockchip,rk817-codec`; mixer `Playback Path` = OFF/SPK/HP/SPK_HP; `Playback Volume` 0–255.

---

## 2. What was compared and tested (in order)

### 2.1 DTB comparison (stock vs dArkOS "Variant 1")
Decompiled both with `dtc`. The only audio-relevant difference: the stock tree drives the speaker-enable **GPIO3_A7** (`spk-con-gpio`) via the multicodecs card; the dArkOS tree never touches that pin. Everything else audio-related is equivalent: I2S1 pins and pull configs, MCLK pin, codec node (`hp-volume 20`, clocks, pinctrl), IO-domain voltages, PMIC regulators (5 V boost always-on in both), headphone detect pin. I2S2 (which shares GPIO3_A7 as `i2s2_sdo`) is disabled in both — no pin conflict.

**First attempt:** a DTB with `spk-ctl-gpios = <&gpio3 7 GPIO_ACTIVE_HIGH>`, `spk-mute-delay-ms = <50>`, `spk-volume = <3>`, a `spk-ctl-pin` pinctrl entry and a `Speaker` widget (same as the dArkOSRE-R36 2541/2548/2549 DTBs). **Did not fix audio.** (dmesg later confirmed the dArkOS kernel does read these properties — they are just not the problem.)

### 2.2 Round 1 — `audio_diag.sh` (system collect + live amp-pin test)
- Confirmed `boot.ini` → `rk3326-g80ca-linux.dtb`, kernel above, card 0 = `rockchip,rk817-codec`, `Playback Path = SPK`, volume 255, `~/.asoundrc` = standard dmix.
- dmesg: `rk817-codec: lookup for GPIO spk-ctl failed / hp-ctl failed` (driver supports the properties, DTB lacks them); harmless `ASoC: no sink widget found for MIC_IN / HPOL / HPOR` routing warnings; I2S/codec/card all probe cleanly.
- `/sys/kernel/debug/gpio`: GPIO3_A7 unclaimed; GPIO2_C6 "Headphone detection" reads **low** with nothing plugged and the jack reports off → polarity flag 0 is correct.
- Live test: exported GPIO3_A7 via sysfs, drove it high, played `Front_Center.wav` in SPK and HP paths → **silent**.

### 2.3 Round 2 — `audio_diag2.sh` (max volume, full-scale 440 Hz tone, 6 combinations, headphone check)
- Amp pin high/low × path SPK/HP/SPK_HP at volume 255 → **silent**. With headphones plugged (jack correctly detected: pin high, `Headphone Jack = on`) → **silent in headphones too**. `hw_params` showed the stream running (44.1 kHz S16 stereo). → The codec itself produces no output; not an amp problem.

### 2.4 Round 3 — `audio_diag3.sh` (clocks during playback)
- `clk_i2s1_out` enabled at 11.2896 / 12.288 MHz during playback; hclk_i2s1 enabled; PCM state RUNNING. → MCLK present.

### 2.5 Round 4 — `audio_diag4.sh`, run on **both** cards (speech clip, 6 amp-pin/path combinations, codec register snapshots)
- **Card A (works):** kernel owns `gpio-103 spk-con`, high during SPK tests, low during HP tests. Codec during SPK playback: `2f=03 30=02 31/32=08 38=10 3e=1f 40=a5 41=f7` (regmap values).
- **Card B (silent):** `2f=00 30=04 31/32=00 38=10 3e=0f 40=a5 41=4c`. GPIO3_A7 natural level 0. Silent in all six tests.

### 2.6 Round 5 — `audio_diag5.sh` hardware snapshot on **both** cards (PMIC regs, raw codec regs over I²C, I2S controller regs idle/playing, regulators, all 128 GPIO levels, bootloader strings)
- **I2S controller registers identical** on both cards during playback: `TXCR=0x0000000f` (16-bit I²S), `CKR=0x00033f3f` (master, MCLK/4 → 48 kHz), `DMACR=0x000f0110`, `XFER=0x3`.
- **Raw codec registers (hardware, not cached) during playback — Card A:** `2f=03 30=04 31/32=08 38=10 39/3a=08 3d=e0 3f=09 40=a5 41=7f 42=04 45=0c 46=a5 47=00 48=00 4b=0f 4c=20`. **Card B:** identical *except* `2f=00`, `31/32=00`, `41=4c` and — the important one — **`39/3a = ff`** (DAC applied-volume readback still at reset/mute) while Card A shows `08` (= its volume setting).
- Regulators: all rails on in both; LDO6/LDO7 at 3.3 V on Card A vs 3.0 V on Card B (not relevant, see below).
- GPIO scan differences: Card A drives gpio0_A0 (`blue_led`) high, gpio0_B3 low, gpio0_B4 high; Card B leaves them as inputs. (Tested in round 7 — they are just LEDs.)

### 2.7 Round 6 — `audio_diag6.sh` (force Card A's codec register values over I²C during playback)
- Wrote `0x41=0xf7` ("restart class-D", reads back `0x7f` as the top bit self-clears), `0x2f=0x03`, then the full vendor speaker sequence (`40=a5 41=f7 38=10 2f=03 30=02 3e=1f`) → **silent**. Codec register *values* are not the difference.

### 2.8 Round 7 — `audio_diag7.sh` (drive the LED GPIOs like the working kernel; re-write DAC volume during playback)
- gpio0_A0/B3/B4 driven → the LED lit; **silent**. Re-writing `0x31/0x32` during playback → `0x39/0x3a` stayed `ff`. → GPIO/LED theory dead; DAC engine confirmed not running.

### 2.9 Round 8 — `audio_diag8.sh` (replay the working driver's codec "kick" sequences over I²C while the clip plays) — **the decisive test**
| Test | What was done 1.5 s into playback | Result | `0x39/0x3a` after |
|---|---|---|---|
| 1 | baseline | silent | `ff/ff` |
| 2 | `rk817_restart_dac_digital_clk`: `0x2f|=0x08` (DAC bias down), `0x15&=~0x08` then `|=0x08` (DAC digital clock off/on), `0x2f` restore | silent | `ff/ff` |
| 3 | same **plus PLL power-cycle**: `0x47|=0x01` (PLL_PW_DOWN), `0x47&=~0x01` (PLL_PW_UP) | **SOUND** | `00/00` |
| 4 | full `rk817_reset()` + playback power-up list + SPK path | sound | `00/00` |
| 5 | full reset *before* the stream starts | sound | `00/00` |
| 6 | write `0x39/0x3a` directly | sound (already working) | `00/00` |

After test 3 the codec stayed working for the rest of the session. **The PLL power-cycle is the single missing step.**

---

## 3. Root cause

On this board the RK817 codec's audio PLL does not come up correctly with the dArkOS 4.4 kernel's `rk817_codec` driver: the driver enables the codec clocks at probe and never power-cycles the PLL / restarts the DAC digital clock afterwards. The Rockchip vendor driver (and whatever kernel the original card runs) calls `rk817_restart_dac_digital_clk_and_apll()` at every playback start:

```c
/* sound/soc/codecs/rk817_codec.c (Rockchip vendor, develop-4.4 and develop-5.10) */
static int rk817_restart_dac_digital_clk_and_apll(struct snd_soc_codec *codec)
{
	snd_soc_update_bits(codec, RK817_CODEC_ADAC_CFG1, PWD_DACBIAS_MASK, PWD_DACBIAS_DOWN);
	usleep_range(500, 600);
	snd_soc_update_bits(codec, RK817_CODEC_DTOP_DIGEN_CLKE, DAC_DIG_CLK_MASK, DAC_DIG_CLK_DIS);
	usleep_range(500, 600);
	snd_soc_update_bits(codec, RK817_CODEC_DTOP_DIGEN_CLKE, DAC_DIG_CLK_MASK, DAC_DIG_CLK_EN);
	snd_soc_update_bits(codec, RK817_CODEC_APLL_CFG5, PLL_PW_DOWN, PLL_PW_DOWN);
	usleep_range(50, 60);
	snd_soc_update_bits(codec, RK817_CODEC_APLL_CFG5, PLL_PW_DOWN, PLL_PW_UP);
	usleep_range(500, 600);
	snd_soc_update_bits(codec, RK817_CODEC_ADAC_CFG1, PWD_DACBIAS_MASK, PWD_DACBIAS_ON);
	return 0;
}
```

Without it the DAC digital engine never runs → the applied-volume readback stays at `0xff` (−95 dB) regardless of the volume setting → silence on both speaker (class-D) and headphone outputs, while I²S, MCLK, clocks, mixer and every other codec register look correct. This is why no DTB change could fix it and why other clone batches (2541/2548/2549) may work on the same kernel — their PLL happens to come up on its own.

Register map used (I²C bus 0, address `0x20`; codec regs = PMIC register addresses): `0x15` DTOP_DIGEN_CLKE, `0x2f` ADAC_CFG1, `0x31/0x32` DDAC_VOLL/R, `0x38` DDAC_MUTE_MIXCTL, `0x39/0x3a` DDAC_RVOLL/R (applied-volume readback), `0x40/0x41` ACLASSD_CFG1/2, `0x47` APLL_CFG5 (bit0 = PLL power down).

---

## 4. The fix (workaround for the current dArkOS build)

`Install Audio Fix.sh` — copy it (and the uninstaller) to the `tools` folder on the EASYROMS partition, run it once from Options → Tools, reboot. It installs:

- `/usr/local/bin/rk817-audio-kick.sh` — the service (bash). Loads `i2c-dev`, then sleeps on two event sources: the `rockchip,rk817-codec Headphones` input device and `alsactl monitor`. On start and on every jack change it sets the `Playback Path` (HP/SPK) and GPIO3_A7, kicks the codec and verifies it (`0x39` applied-volume readback must not be `0xff`), holds the path against the hotkey daemon's wrong switch, and applies the headphone level. It also turns the `Master` volume control into the codec volume. Log: `/tmp/rk817-audio-kick.log`.
- `/usr/local/bin/rk817-codec` — a one-shot Python helper that does the I²C register work in atomic SMBus transactions (runs for a fraction of a second per kick). The kick sequence:
  ```
  0x2f |= 0x08   (DAC bias down)
  0x15 &= ~0x08  (DAC digital clock off)
  0x15 |= 0x08   (DAC digital clock on)
  0x47 |= 0x01   (PLL power down)
  0x47 &= ~0x01  (PLL power up)
  0x2f &= ~0x08  (DAC bias on)
  ```
  afterwards it checks bias, DAC clock and PLL bits are in their working state and repairs them if not.
- `/usr/local/bin/amixer` — a small wrapper so the volume keys step the `Master` control (2 dB per press) and set the codec at once; everything else passes through to the real `amixer`.
- `Master Playback Volume` — a user-defined ALSA control (0–100), saved with the normal mixer state so it exists before EmulationStation starts.
- `/etc/systemd/system/rk817-audio-kick.service` (enabled, `Restart=always`) and `/lib/systemd/system-sleep/rk817-audio-kick` (re-kick after resume).

`Uninstall Audio Fix.sh` removes all of it, including the `Master` control.

Codec registers used beyond section 3: `0x3d` AHP_CFG0 (bits 4:3 headphone amplitude boost), `0x3e` AHP_CFG1 (bit 4 anti-pop enable, bits 3:0 anti-pop attenuation 0…−15 dB), `0x41` ACLASSD_CFG2 (class-D over-current limits; no gain setting exists for the class-D amplifier), from the RK809/RK817 datasheet register description.

**Result:** EmulationStation menu sounds and games play through the speaker and headphones on dArkOS, with correct switching between them.

## 5. Suggested proper fix for the kernel

In the ArkOS4Clone / dArkOSRE `rk817_codec.c`, call `rk817_restart_dac_digital_clk_and_apll()` (or at least the `APLL_CFG5` power-cycle) in the playback path set / stream start, as the vendor driver does. That would make batch 2551 work out of the box with the existing "R36S-V20 2025-05-18" DTBs (the 2541 DTB has the same panel init sequence as this board's stock DTB, plus the GPIO3_A7 speaker enable).

## 6. Files in this repository

- `fix/Install Audio Fix.sh`, `fix/Uninstall Audio Fix.sh` — the fix (v2.2).
- `diagnostics/audio_diag8.sh` + `evidence/report8.txt` — the decisive experiment and its log.
- `evidence/report4_darkos_card.txt` / `evidence/report5_original_card.txt` — register/clock/GPIO snapshots; `evidence/dmesg_darkos_card.txt`.
- `dtb/rf3536k3ka.dtb` (stock) and `dtb/rk3326-g80ca-linux.dtb` (dArkOS Variant 1) for reference.

Diagnosis was done with a series of shell/Python scripts run from the Tools menu (sysfs GPIO, `/sys/kernel/debug` regmap/clk/gpio, raw I²C via `/dev/i2c-0`), comparing the working original card against dArkOS on the same unit, and against the Rockchip vendor driver sources (`rockchip-linux/kernel` develop-4.4 / develop-5.10).
