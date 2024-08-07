const path = require('path');

module.exports = {
  entry: {
    wallet: './public/js/wallet.js',
    setAuthorizer: './public/js/set-authorizer.js',
    pools: './public/js/pools.js',
    home: './public/js/home.js',
    index: './public/js/index.js',
    welcome: './public/js/welcome.js',
    common: './public/js/common.js'
  },
  output: {
    filename: '[name].bundle.js',
    path: path.resolve(__dirname, 'public/js/bundle'),
  },
  module: {
    rules: [
      {
        test: /\.js$/,
        exclude: /node_modules/,
        use: {
          loader: 'babel-loader',
          options: {
            presets: ['@babel/preset-env', '@babel/preset-react'],
          },
        },
      },
    ],
  },
  resolve: {
    fallback: {
      fs: false,
      path: require.resolve('path-browserify'),
      buffer: require.resolve('buffer/'),
    },
  },
};
