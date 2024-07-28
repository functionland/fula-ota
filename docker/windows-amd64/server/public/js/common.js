// Set the version number
const VERSION = "1.0.0";

// Function to set version number in the footer
function setVersionNumber() {
    const versionElement = document.getElementById('version-number');
    if (versionElement) {
        versionElement.textContent = VERSION;
    }
}

// Function to clear local storage
function clearLocalStorage() {
    localStorage.clear();
    console.log("Local storage has been cleared.");
}

// Function to handle reset button click
function handleResetClick() {
    if (confirm("Are you sure you want to clear local storage and reset the setup?")) {
        clearLocalStorage();
        alert("Local storage has been cleared and setup reset.");
        // You can add any additional reset logic here
    }
}

// Set up event listeners when the DOM is fully loaded
document.addEventListener('DOMContentLoaded', function() {
    setVersionNumber();

    const resetButton = document.getElementById('reset-button');
    if (resetButton) {
        resetButton.addEventListener('click', handleResetClick);
    }
});
