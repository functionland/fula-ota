const express = require('express');
const { exec } = require('child_process');
const router = express.Router();

router.get('/', (req, res) => {
    const command = `docker exec fula_go curl -s http://localhost:3500/account/seed`;

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
            // Return a 200 status with an empty account seed
            return res.status(200).json({ accountSeed: '' });
        }

        const accountSeed = response.accountSeed ? response.accountSeed.trim() : '';
        res.status(200).json({ accountSeed });
    });
});

module.exports = router;
