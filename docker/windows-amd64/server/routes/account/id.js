const express = require('express');
const { exec } = require('child_process');
const router = express.Router();

router.get('/', (req, res) => {
    const command = `docker exec fula_go curl -s http://localhost:3500/account/id`;

    exec(command, (error, stdout, stderr) => {
        if (error) {
            console.error(`Error: ${error.message}`);
            return res.status(500).send(`Server error: ${error.message}`);
        }
        if (stderr) {
            console.error(`Stderr: ${stderr}`);
            return res.status(500).send(`Server error: ${stderr}`);
        }
        const response = JSON.parse(stdout);
        const accountId = response.accountId.trim();
        res.json({ accountId });
    });
});

module.exports = router;
