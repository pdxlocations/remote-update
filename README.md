# Meshtastic serial update checker

Run `update-check.sh` on the Luckfox Lyra over SSH. It reads the connected node's firmware through the Meshtastic CLI and lists the five most recent GitHub releases labelled Alpha or Beta. You may choose any listed release, including an older version.

Install the CLI once (along with `curl` and `python3`):

```sh
python3 -m pip install --user 'meshtastic[cli]'
```

Then copy the script to the Luckfox and run:

```sh
chmod +x update-check.sh
./update-check.sh --port /dev/ttyUSB0
```

If exactly one `/dev/ttyUSB*` or `/dev/ttyACM*` device exists, `--port` is optional. The script only downloads release metadata before the prompt. After you choose a release and firmware archive, it downloads the archive, lets you select the matching `*-update.bin`, then runs that archive's `device-update.sh -p PORT -f FILE`. Use `--dry-run` to list releases without downloading or flashing. This is the normal update path, not the destructive `device-install.sh` erase-and-install path; keep a configuration backup and ensure stable power while flashing.
