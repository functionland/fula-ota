const express = require('express');
const { exec } = require('child_process');
const router = express.Router();

router.get('/', (req, res) => {
    const command = `docker exec fula_go curl -s http://localhost:3500/chain/status`;

    exec(command, (error, stdout, stderr) => {
        if (error) {
            console.error(`Error: ${error.message}`);
            return res.status(500).send(`Server error: ${error.message}`);
        }
        if (stderr) {
            console.error(`Stderr: ${stderr}`);
            return res.status(500).send(`Server error: ${stderr}`);
        }

        try {
            const response = JSON.parse(stdout);
            res.json(response);
        } catch (parseError) {
            console.error(`JSON parse error: ${parseError.message}`);
            return res.status(500).send(`Server error: ${parseError.message}`);
        }
    });
});

module.exports = router;
