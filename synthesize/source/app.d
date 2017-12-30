import dlangui;
import synthesize;
import songsketch;

mixin APP_ENTRY_POINT;

/// entry point for dlangui based application
extern (C) int UIAppMain(string[] args) {
    bool sketch = false;

    foreach (x; args) {
        if (x == "--sketch")
            sketch = true;
    }

    return sketch ? sketch_main(args) : syn_main(args); /* call own main function */
}
