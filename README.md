# MFD-CarPlay
![IMG_3974](https://github.com/user-attachments/assets/cc56ef14-f076-45bd-b7d5-588ebdd775c3)

# MFD-CarPlay

This project enables the integration of Apple CarPlay into the VW Radio Navigation System MFD (1999 model) using a Raspberry Pi HAT and custom software.

## Overview

The goal of this project is to bring modern smartphone integration (Apple CarPlay) into older car infotainment systems. By using a Raspberry Pi and the necessary components, users can bring modern technologies into their older vehicle's multimedia system.

## Features

- Integration of Apple CarPlay into the VW MFD Radio Navigation System (1999 model).
- Uses a Raspberry Pi HAT for communication with the MFD system.
- Custom software to handle CarPlay functionality.

## Requirements

- Raspberry Pi (Model 3 or newer recommended)
- Raspberry Pi HAT
- VW Radio Navigation System MFD (1999 model)
- Dependencies (listed below)

## Installation

1. **Prepare the Raspberry Pi:**
   - Install the required OS on the Raspberry Pi.
   - Make sure the Raspberry Pi can communicate with the MFD system.

2. **Install the Software:**
   - Clone this repository to your Raspberry Pi:
     ```bash
     git clone https://github.com/JKBusse/MFD-CarPlay.git
     ```

3. **Run the Installation Script:**
   - Execute the installation script:
     ```bash
     cd MFD-CarPlay
     ./install.sh
     ```

4. **Connect the Hardware:**
   - Connect the Raspberry Pi to the VW MFD system using the appropriate cables.

5. **Start the Software:**
   - Run the CarPlay software and check the connection.

## Troubleshooting

- Ensure the Raspberry Pi is correctly powered and properly connected to the MFD system.
- Double-check the configuration files for any missing or incorrect settings.

## Contributing

If you'd like to contribute to this project, feel free to fork the repository and submit pull requests. Any feedback or improvements are welcome!

## License

This project is open source and available under the MIT License.
