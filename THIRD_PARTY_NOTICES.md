# Third-Party Notices

This repository and produced images make use of third-party software. Licensing of these components remains with their respective authors.

## Included or Downloaded During Build

1. LIVI
- Source: https://github.com/f-io/LIVI
- License: GPL-3.0-or-later (see upstream repository)
- Usage: Downloaded as AppImage and installed into the image.

2. Raspberry Pi OS
- Source: https://downloads.raspberrypi.org/
- License: Mixed Debian/Raspberry Pi package licensing (see `/usr/share/doc/*/copyright` in the image)
- Usage: Base image used for customization.

3. gh-large-releases action
- Source: https://github.com/ading2210/gh-large-releases
- License: See upstream repository
- Usage: Release artifact publishing in CI.

## Runtime Package Dependencies

The build process installs additional Debian/Raspberry Pi packages (for example graphics, audio, Bluetooth, networking, and system services). Each package keeps its own license metadata inside the final image under `/usr/share/doc/<package>/copyright`.

## Trademark Notice

Apple, Apple CarPlay, and related marks are trademarks of Apple Inc. This project is independent and not endorsed by Apple.
