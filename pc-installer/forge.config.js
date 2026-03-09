module.exports = {
  packagerConfig: {
    asar: true,
    name: 'Fula Node',
    icon: 'src/assets/icons/icon',
    extraResource: ['templates'],
  },
  makers: [
    {
      name: '@electron-forge/maker-squirrel',
      config: {
        name: 'FulaNode',
        iconUrl: 'src/assets/icons/icon.ico',
        setupIcon: 'src/assets/icons/icon.ico',
      },
    },
    {
      name: '@electron-forge/maker-deb',
      config: {
        options: {
          icon: 'src/assets/icons/icon.png',
          maintainer: 'Functionland',
          homepage: 'https://fx.land',
        },
      },
    },
    {
      name: '@electron-forge/maker-zip',
      platforms: ['darwin', 'linux', 'win32'],
    },
  ],
};
