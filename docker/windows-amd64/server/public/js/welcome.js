document.addEventListener('DOMContentLoaded', () => {
    fetch('/api/properties')
        .then(response => response.json())
        .then(data => {
            const tableBody = document.querySelector('#properties-table tbody');

            const properties = [
                { name: 'Fula Image Date', value: data.containerInfo_fula.created },
                { name: 'FxSupport Image Date', value: data.containerInfo_fxsupport.created },
                { name: 'Hardware ID', value: data.hardwareID },
                { name: 'OTA Version', value: data.ota_version }
            ];

            properties.forEach(property => {
                const row = document.createElement('tr');
                row.innerHTML = `
                    <td>${property.name}</td>
                    <td>${property.value}</td>
                `;
                tableBody.appendChild(row);
            });
        })
        .catch(error => console.error('Error fetching properties:', error));

    document.getElementById('view-terms').addEventListener('click', () => {
        window.open('https://fx.land/terms', '_blank');
    });

    document.getElementById('accept-terms').addEventListener('click', () => {
        localStorage.setItem('setup_started', 'true');
        window.location.href = '/webui/connect-to-wallet';
    });
});
