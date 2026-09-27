# Diagnostic scripts

Run from EmulationStation → Tools (copy into the `tools` folder on EASYROMS). Each writes an `*_out` folder next to itself.

| Script | What it does | What it showed on the 2551 |
|---|---|---|
| `audio_diag.sh` | Collects boot config, live DTB, ALSA state, dmesg, GPIO state; live speaker-enable GPIO test | Kernel/DTB identified; codec driver supports spk-ctl-gpios; GPIO3_A7 high alone = no sound |
| `audio_diag2.sh` | Max-volume 440 Hz tone across amp-pin/path combinations + headphone check | Silent everywhere, even headphones → codec produces no output |
| `audio_diag3.sh` | Clock tree and PCM state during playback | MCLK 12.288 MHz present, stream running |
| `audio_diag4.sh` | Speech clip across combinations, codec register snapshots (run on both cards) | Working card drives spk-con; register values differ (0x41, 0x2f) |
| `audio_diag5.sh` | Hardware snapshot: PMIC, raw codec regs, I2S controller, regulators, all GPIO levels (run on both cards) | I2S identical; applied-volume readback 0x39/0x3a = ff on dArkOS vs 08 on working card |
| `audio_diag6.sh` | Forces the working card's codec register values during playback | No effect → values are not the difference |
| `audio_diag7.sh` | Drives the LED GPIOs like the working kernel; re-writes DAC volume | LEDs only; readback stays ff |
| `audio_diag8.sh` | Replays the vendor driver's DAC-clock restart, PLL power-cycle and full reset during playback | **PLL power-cycle brings sound** → root cause |
