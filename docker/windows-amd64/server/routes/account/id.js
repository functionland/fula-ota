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

        let response;
        try {
            response = JSON.parse(stdout);
        } catch (parseError) {
            console.error(`JSON Parse Error: ${parseError.message}`);
            // Return a 200 status with an empty account ID
            return res.status(200).json({ accountId: '' });
        }

        const accountId = response.accountId ? response.accountId.trim() : '';
        res.status(200).json({ accountId });
    });
});

module.exports = router;
