const winston = require('winston');
const path = require('path');

/**
 * Create a winston logger that writes to both console and a rotating log file.
 * @param {string} logDir - Directory where log files will be stored.
 * @returns {winston.Logger}
 */
function createLogger(logDir) {
  const transports = [new winston.transports.Console()];

  if (logDir) {
    transports.push(
      new winston.transports.File({
        filename: path.join(logDir, 'fula-node.log'),
        maxsize: 10 * 1024 * 1024, // 10 MB
        maxFiles: 5,
        tailable: true,
      })
    );
  }

  return winston.createLogger({
    level: 'info',
    format: winston.format.combine(
      winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
      winston.format.printf(
        ({ timestamp, level, message }) => `${timestamp} [${level}] ${message}`
      )
    ),
    transports,
  });
}

/**
 * Default console-only logger for use before the data directory is configured.
 */
const defaultLogger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
    winston.format.printf(
      ({ timestamp, level, message }) => `${timestamp} [${level}] ${message}`
    )
  ),
  transports: [new winston.transports.Console()],
});

module.exports = { createLogger, defaultLogger };
