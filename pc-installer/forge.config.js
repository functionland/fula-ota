const path = require('path');

module.exports = {
  packagerConfig: {
    asar: true,
    name: 'Fula Node',
    executableName: 'fula-node',
    icon: 'src/assets/icons/fula',
    extraResource: ['templates'],
  },
  makers: [
    {
      name: '@electron-forge/maker-squirrel',
      config: {
        name: 'FulaNode',
        authors: 'Functionland',
        description: 'Fula Node for PC — run a Fula decentralized storage node on your computer',
        setupIcon: 'src/assets/icons/fula.ico',
      },
    },
    {
      name: '@electron-forge/maker-appx',
      config: {
        publisher: 'CN=E9FEC2DC-DBBE-45BA-A112-26EFEA253DB5',
        publisherDisplayName: 'Functionland',
        identityName: 'Functionland.FunctionlandFulaCloud',
        applicationDescription: 'Fula Node for PC — run a Fula decentralized storage node on your computer',
        packageExecutable: 'app/fula-node.exe',
        assets: path.join(__dirname, 'src', 'assets', 'appx-tiles'),
        devCert: process.env.MSIX_DEV_CERT || path.join(require('os').homedir(), 'FulaNodeDevCert.pfx'),
        certPass: '',
      },
      platforms: ['win32'],
    },
    {
      name: '@electron-forge/maker-deb',
      config: {
        options: {
          icon: 'src/assets/icons/fula.ico',
          maintainer: 'Functionland',
          homepage: 'https://fx.land',
        },
      },
    },
    {
      name: '@electron-forge/maker-appx',
      config: {
        publisher: 'CN=E9FEC2DC-DBBE-45BA-A112-26EFEA253DB5',
        publisherDisplayName: 'Functionland',
        identityName: 'Functionland.FunctionlandFulaCloud',
        applicationDescription: 'Fula Node for PC — run a Fula decentralized storage node on your computer',
        packageExecutable: 'app/fula-node.exe',
        devCert: process.env.MSIX_DEV_CERT || require('path').join(require('os').homedir(), 'FulaNodeDevCert.pfx'),
        certPass: '',
      },
      platforms: ['win32'],
    },
    {
      name: '@electron-forge/maker-zip',
      platforms: ['darwin', 'linux', 'win32'],
    },
  ],
};
