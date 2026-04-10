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
        publisher: 'CN=Functionland',
        publisherDisplayName: 'Functionland',
        identityName: 'Functionland.FulaNode',
        applicationDescription: 'Fula Node for PC — run a Fula decentralized storage node on your computer',
        devCert: 'FulaNodeDevCert',
        certProfileName: 'FulaNodeDevCert',
      },
      platforms: ['win32'],
    },
    {
      name: '@electron-forge/maker-zip',
      platforms: ['darwin', 'linux', 'win32'],
    },
  ],
};
