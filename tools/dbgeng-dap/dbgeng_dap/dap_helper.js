"use strict";
// Loaded into cdb with .scriptload by dbgeng-dap.
// dx cannot address every child it displays with a C++ expression (natvis synthetic items such as
// "[Pairs]", base-class sub-objects, iterated container items with sparse indices).  kid() returns such
// a child from the data-model object itself, so the adapter can expand it with `dx -r1 @$dapkid(...)`.

function kid(o, key, ordinal) {
    if (key !== undefined && key !== null && key !== "") {
        var v;
        try { v = o[key]; } catch (e) { v = undefined; }
        if (v !== undefined) {
            return v;
        }
    }
    if (ordinal !== undefined && ordinal >= 0) {
        var i = 0;
        for (var c of o) {
            if (i === ordinal) {
                return c;
            }
            i++;
        }
    }
    throw new Error("child not found: " + key);
}

function initializeScript() {
    return [new host.functionAlias(kid, "dapkid")];
}
