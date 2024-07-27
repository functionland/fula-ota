/*
 * ATTENTION: The "eval" devtool has been used (maybe by default in mode: "development").
 * This devtool is neither made for production nor for readable output files.
 * It uses "eval()" calls to create a separate source file in the browser devtools.
 * If you are trying to read the output file, select a different devtool (https://webpack.js.org/configuration/devtool/)
 * or disable the default devtool with "devtool: false".
 * If you are looking for production-ready output files, see mode: "production" (https://webpack.js.org/configuration/mode/).
 */
/******/ (() => { // webpackBootstrap
/******/ 	var __webpack_modules__ = ({

/***/ "./public/js/welcome.js":
/*!******************************!*\
  !*** ./public/js/welcome.js ***!
  \******************************/
/***/ (() => {

eval("document.addEventListener('DOMContentLoaded', function () {\n  fetch('/api/properties').then(function (response) {\n    return response.json();\n  }).then(function (data) {\n    var tableBody = document.querySelector('#properties-table tbody');\n    var properties = [{\n      name: 'Fula Image Date',\n      value: data.containerInfo_fula.created\n    }, {\n      name: 'FxSupport Image Date',\n      value: data.containerInfo_fxsupport.created\n    }, {\n      name: 'Node Image Date',\n      value: data.containerInfo_node.created\n    }, {\n      name: 'Hardware ID',\n      value: data.hardwareID\n    }, {\n      name: 'OTA Version',\n      value: data.ota_version\n    }];\n    properties.forEach(function (property) {\n      var row = document.createElement('tr');\n      row.innerHTML = \"\\n                    <td>\".concat(property.name, \"</td>\\n                    <td>\").concat(property.value, \"</td>\\n                \");\n      tableBody.appendChild(row);\n    });\n  })[\"catch\"](function (error) {\n    return console.error('Error fetching properties:', error);\n  });\n  document.getElementById('view-terms').addEventListener('click', function () {\n    window.open('https://fx.land/terms', '_blank');\n  });\n  document.getElementById('accept-terms').addEventListener('click', function () {\n    localStorage.setItem('setup_started', 'true');\n    window.location.href = '/webui/connect-to-wallet';\n  });\n});\n\n//# sourceURL=webpack://fula-webui/./public/js/welcome.js?");

/***/ })

/******/ 	});
/************************************************************************/
/******/ 	
/******/ 	// startup
/******/ 	// Load entry module and return exports
/******/ 	// This entry module can't be inlined because the eval devtool is used.
/******/ 	var __webpack_exports__ = {};
/******/ 	__webpack_modules__["./public/js/welcome.js"]();
/******/ 	
/******/ })()
;