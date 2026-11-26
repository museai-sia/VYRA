//
//  PyBridge.c
//  VYRA — CPython embedding: one `_host` module in, JSON strings across.
//
//  Written directly against the CPython C API (docs.python.org/3/c-api)
//  and BeeWare's Python-Apple-support layout: the interpreter home is
//  <resources>/python, third-party packages live in
//  <resources>/app_packages (a site dir), and VYRA's own Python modules
//  live in <resources>/pybridge.
//
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdlib.h>
#include <string.h>

#include "PyBridge.h"

static vyra_js_runner_t js_runner = NULL;
static vyra_js_runner_t pot_js_runner = NULL;
static vyra_js_runner_t pot_reset_runner = NULL;
static PyObject *bridge_module = NULL;

void vyra_python_set_js_runner(vyra_js_runner_t runner) {
    js_runner = runner;
}

void vyra_python_set_pot_js_runner(vyra_js_runner_t runner) {
    pot_js_runner = runner;
}

void vyra_python_set_pot_reset_runner(vyra_js_runner_t runner) {
    pot_reset_runner = runner;
}

#pragma mark - _host module (Python -> app)

static PyObject *host_run_js(PyObject *self, PyObject *args) {
    (void)self;
    const char *code = NULL;
    if (!PyArg_ParseTuple(args, "s", &code)) {
        return NULL;
    }
    if (js_runner == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "JavaScript runner is not configured");
        return NULL;
    }

    char *out = NULL;
    int is_error = 0;
    // JavaScriptCore evaluation can take seconds; release the GIL so
    // status polling from other threads is not blocked meanwhile.
    Py_BEGIN_ALLOW_THREADS
    out = js_runner(code, &is_error);
    Py_END_ALLOW_THREADS

    if (out == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "JavaScript runner returned no output");
        return NULL;
    }
    PyObject *result = NULL;
    if (is_error) {
        PyErr_SetString(PyExc_RuntimeError, out);
    } else {
        result = PyUnicode_FromString(out);
    }
    free(out);
    return result;
}

/// Shared implementation for the POT runners: pass one string to a
/// registered Swift callback (releasing the GIL — evaluations and
/// WebView round trips can take seconds) and return its output.
static PyObject *call_string_runner(vyra_js_runner_t runner, const char *input,
                                    const char *missing_message) {
    if (runner == NULL) {
        PyErr_SetString(PyExc_RuntimeError, missing_message);
        return NULL;
    }
    char *out = NULL;
    int is_error = 0;
    Py_BEGIN_ALLOW_THREADS
    out = runner(input, &is_error);
    Py_END_ALLOW_THREADS

    if (out == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "POT JavaScript runner returned no output");
        return NULL;
    }
    PyObject *result = NULL;
    if (is_error) {
        PyErr_SetString(PyExc_RuntimeError, out);
    } else {
        result = PyUnicode_FromString(out);
    }
    free(out);
    return result;
}

static PyObject *host_pot_js(PyObject *self, PyObject *args) {
    (void)self;
    const char *code = NULL;
    if (!PyArg_ParseTuple(args, "s", &code)) {
        return NULL;
    }
    return call_string_runner(pot_js_runner, code,
                              "POT JavaScript runner is not configured");
}

static PyObject *host_pot_js_reset(PyObject *self, PyObject *args) {
    (void)self;
    const char *preference = NULL;
    if (!PyArg_ParseTuple(args, "s", &preference)) {
        return NULL;
    }
    return call_string_runner(pot_reset_runner, preference,
                              "POT reset runner is not configured");
}

static PyMethodDef host_methods[] = {
    {"run_js", host_run_js, METH_VARARGS,
     "Evaluate JavaScript with JavaScriptCore; returns console.log output."},
    {"pot_js", host_pot_js, METH_VARARGS,
     "Evaluate JavaScript in the persistent POT environment; "
     "returns the evaluation's completion value (JSON string)."},
    {"pot_js_reset", host_pot_js_reset, METH_VARARGS,
     "Reset the persistent POT environment for a backend preference; "
     "returns a JSON string describing the chosen backend."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef host_module_def = {
    PyModuleDef_HEAD_INIT, "_host", NULL, -1, host_methods,
};

static PyObject *PyInit_host(void) {
    return PyModule_Create(&host_module_def);
}

#pragma mark - Error helpers

/// Builds a {"ok": false, "error": message} JSON string.
static char *error_json(const char *message) {
    PyObject *json_module = PyImport_ImportModule("json");
    PyObject *dumped = NULL;
    if (json_module != NULL) {
        PyObject *msg = PyUnicode_FromString(message);
        dumped = PyObject_CallMethod(json_module, "dumps", "{s:O,s:O}",
                                     "ok", Py_False, "error", msg);
        Py_XDECREF(msg);
        Py_DECREF(json_module);
    }
    char *result = NULL;
    if (dumped != NULL) {
        const char *utf8 = PyUnicode_AsUTF8(dumped);
        result = utf8 ? strdup(utf8) : NULL;
        Py_DECREF(dumped);
    }
    if (result == NULL) {
        PyErr_Clear();
        result = strdup("{\"ok\": false, \"error\": \"Internal bridge error\"}");
    }
    return result;
}

/// Formats and clears the pending exception as a malloc'd string.
static char *take_exception_message(void) {
    PyObject *exc = PyErr_GetRaisedException();
    if (exc == NULL) {
        return strdup("Unknown Python error");
    }
    PyObject *str = PyObject_Str(exc);
    const char *utf8 = str ? PyUnicode_AsUTF8(str) : NULL;
    char *message = strdup(utf8 ? utf8 : "Unprintable Python error");
    Py_XDECREF(str);
    PyErr_Clear();

    // Keep the full traceback in the system log for debugging.
    PyErr_SetRaisedException(exc);
    PyErr_Print();
    return message;
}

#pragma mark - Interpreter lifecycle

char *vyra_python_initialize(const char *resource_path) {
    if (PyImport_AppendInittab("_host", PyInit_host) == -1) {
        return strdup("Could not register the _host module");
    }

    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        return strdup(status.err_msg ? status.err_msg : "Py_PreInitialize failed");
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0; // the app bundle is read-only
    config.install_signal_handlers = 0;

    char path[4096];
    snprintf(path, sizeof(path), "%s/python", resource_path);
    status = PyConfig_SetBytesString(&config, &config.home, path);
    if (!PyStatus_Exception(status)) {
        status = Py_InitializeFromConfig(&config);
    }
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        return strdup(status.err_msg ? status.err_msg : "Py_InitializeFromConfig failed");
    }

    char *error = NULL;

    // app_packages is a site directory (third-party packages).
    snprintf(path, sizeof(path), "%s/app_packages", resource_path);
    PyObject *site = PyImport_ImportModule("site");
    PyObject *added = site ? PyObject_CallMethod(site, "addsitedir", "s", path) : NULL;
    if (added == NULL) {
        error = take_exception_message();
    }
    Py_XDECREF(added);
    Py_XDECREF(site);

    // pybridge holds VYRA's own Python modules.
    if (error == NULL) {
        snprintf(path, sizeof(path), "%s/pybridge", resource_path);
        PyObject *sys_path = PySys_GetObject("path"); // borrowed
        PyObject *entry = PyUnicode_FromString(path);
        if (sys_path == NULL || entry == NULL || PyList_Insert(sys_path, 0, entry) != 0) {
            error = take_exception_message();
        }
        Py_XDECREF(entry);
    }

    if (error == NULL) {
        bridge_module = PyImport_ImportModule("vyra_bridge");
        if (bridge_module == NULL) {
            error = take_exception_message();
        }
    }

    // Release the GIL so calls can be made from any thread.
    PyEval_SaveThread();
    return error;
}

char *vyra_python_call(const char *function, const char *json_arg) {
    if (bridge_module == NULL) {
        return strdup("{\"ok\": false, \"error\": \"Python is not initialized\"}");
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    char *result = NULL;
    PyObject *value = PyObject_CallMethod(bridge_module, function, "s", json_arg);
    if (value != NULL && PyUnicode_Check(value)) {
        const char *utf8 = PyUnicode_AsUTF8(value);
        result = utf8 ? strdup(utf8) : NULL;
    }
    if (result == NULL) {
        char *message = PyErr_Occurred()
            ? take_exception_message()
            : strdup("Bridge function did not return a string");
        result = error_json(message);
        free(message);
    }
    Py_XDECREF(value);
    PyGILState_Release(gil);
    return result;
}
