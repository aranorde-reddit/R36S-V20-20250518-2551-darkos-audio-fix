# R36S clone V20 2025-05-18 (batch 2551) — dArkOS audio fix

**No sound at all on dArkOS (speaker and headphones) on the R36S clone motherboard `R36S-V20 2025-05-18 2551`?** This repository contains the root cause, the evidence, and a working one-click fix.

## Quick fix (2 minutes)

1. Download [`fix/Install Audio Fix.sh`](fix/Install%20Audio%20Fix.sh) (click the file, then the download icon).
2. Put it in the `tools` folder on your ROMs partition (EASYROMS).
3. On the device: EmulationStation → **Tools** → run **Install Audio Fix**. Reboot.
4. Menus, games, speaker and headphones now work. `fix/Uninstall Audio Fix.sh` removes it again.

Tested on dArkOS-G80CA-RE 10/02/2026 (kernel 4.4.189 #86, lcdyk). It should apply to any dArkOS / ArkOS4Clone build on this kernel line; if your board is a different batch and you have the same "everything looks right but nothing plays" symptom, it's worth trying.

## Project status

This was a spare-time investigation on my own unit, worked through step by step with Claude (Anthropic's AI) doing the analysis, and it ends here: the fix works on my device and I don't have other boards or the time to carry it further. It isn't actively maintained. If you have a different batch or another dArkOS build, the diagnostic scripts and evidence are all here — please test, fork, and improve freely (MIT licence). The permanent fix belongs in the kernel's `rk817_codec` driver; if a maintainer picks that up, this repository will have done its job.

## Repository layout

- `fix/` — the installer and uninstaller (a small systemd service that performs the codec PLL restart the kernel driver is missing).
- `diagnostics/` — the eight test scripts used to find the cause, in order (`audio_diag.sh` … `audio_diag8.sh`). Run from the Tools menu; each writes a report folder next to itself.
- `evidence/` — the reports from the decisive runs (dArkOS card and the original working card).
- `dtb/` — the stock DTB (`rf3536k3ka.dtb`) and the dArkOS "Variant 1" DTB for reference.

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

`Install Audio Fix.sh` (attached) — copy it to the `tools` folder on the EASYROMS partition, run it once from EmulationStation → Tools, reboot. It installs:

- `/usr/local/bin/rk817-audio-kick.py` — at start: loads `i2c-dev`, holds GPIO3_A7 high (speaker enable, harmless if unused), opens a silent ALSA stream and performs the kick over I²C:
  ```
  0x2f |= 0x08   (DAC bias down)
  0x15 &= ~0x08  (DAC digital clock off)
  0x15 |= 0x08   (DAC digital clock on)
  0x47 |= 0x01   (PLL power down)
  0x47 &= ~0x01  (PLL power up)
  0x2f &= ~0x08  (DAC bias on)
  ```
  then watches the `rockchip,rk817-codec Headphones` input device and repeats the kick 0.8 s after every headphone plug/unplug (dArkOS switches the audio path then). Log: `/tmp/rk817-audio-kick.log`.
- `/etc/systemd/system/rk817-audio-kick.service` (enabled, `Restart=always`).
- `/lib/systemd/system-sleep/rk817-audio-kick` — restarts the service after resume.

`Uninstall Audio Fix.sh` removes all of it.

**Result:** after reboot, EmulationStation menu sounds and games (tested Mario 64) play through the speaker on dArkOS.

## 5. Suggested proper fix for the kernel

In the ArkOS4Clone / dArkOSRE `rk817_codec.c`, call `rk817_restart_dac_digital_clk_and_apll()` (or at least the `APLL_CFG5` power-cycle) in the playback path set / stream start, as the vendor driver does. That would make batch 2551 work out of the box with the existing "R36S-V20 2025-05-18" DTBs (the 2541 DTB has the same panel init sequence as this board's stock DTB, plus the GPIO3_A7 speaker enable).

## 6. Files in this repository

- `fix/Install Audio Fix.sh`, `fix/Uninstall Audio Fix.sh` — the fix.
- `diagnostics/audio_diag8.sh` + `evidence/report8.txt` — the decisive experiment and its log.
- `evidence/report4_darkos_card.txt` / `evidence/report5_original_card.txt` — register/clock/GPIO snapshots; `evidence/dmesg_darkos_card.txt`.
- `dtb/rf3536k3ka.dtb` (stock) and `dtb/rk3326-g80ca-linux.dtb` (dArkOS Variant 1) for reference.

Diagnosis was done with a series of shell/Python scripts run from the Tools menu (sysfs GPIO, `/sys/kernel/debug` regmap/clk/gpio, raw I²C via `/dev/i2c-0`), comparing the working original card against dArkOS on the same unit, and against the Rockchip vendor driver sources (`rockchip-linux/kernel` develop-4.4 / develop-5.10).
