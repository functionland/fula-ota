const express = require('express');
const { exec } = require('child_process');
const router = express.Router();

router.post('/', (req, res) => {
  const { seed } = req.body;
  const command = `docker exec fula_go curl -s -X POST -d "seed=${seed}" http://localhost:3500/peer/generate-identity`;


  exec(command, (error, stdout, stderr) => {
    if (error) {
      console.error(`Error: ${error.message}`);
      console.error(`Command: ${command}`);
      return res.status(500).send(`Server error: ${error.message}`);
    }
    if (stderr) {
      console.error(`Stderr: ${stderr}`);
      console.error(`Command: ${command}`);
      return res.status(500).send(`Server error: ${stderr}`);
    }
    res.send(stdout);
  });
});

module.exports = router;
