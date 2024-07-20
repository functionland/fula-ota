const express = require('express');
const { exec } = require('child_process');
const router = express.Router();

router.post('/', (req, res) => {
    const { container } = req.body;
    const command = `docker restart ${container}`;

    exec(command, (error, stdout, stderr) => {
        if (error) {
            console.error(`Error restarting container ${container}: ${error.message}`);
            return res.status(500).send(`Server error: ${error.message}`);
        }
        if (stderr) {
            console.error(`Stderr while restarting container ${container}: ${stderr}`);
            return res.status(500).send(`Server error: ${stderr}`);
        }
        res.send(`Container ${container} restarted successfully`);
    });
});

module.exports = router;
