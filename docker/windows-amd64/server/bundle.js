const browserify = require('browserify');
const fs = require('fs');

browserify('public/js/hdkey-bundle.js')
  .transform('babelify', {
    presets: ['@babel/preset-env'],
    sourceMaps: false,
  })
  .bundle()
  .pipe(fs.createWriteStream('public/js/hdkey-bundle.bundle.js'));
