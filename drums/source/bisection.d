module bisection;

/** returns the smallest index i, where sorted_array[i] > x */

ulong bisect(alias lt = (a, b) => a < b, X)(X[] sorted_array, X x) {
    ulong lo = 0;
    ulong hi = sorted_array.length;

    while (lo < hi) {
        if (lo == hi)
            return lo;
        ulong mid = (lo + hi) / 2;
        if (lt(x, sorted_array[cast(uint)mid]))
            hi = mid;
        else
            lo = mid + 1;
    }
    return lo;
}

bool bisect_contains(alias lt = (a, b) => a < b, X)(const X[] sorted_array, X x) {
    if (X.length == 0)
        return false;

    auto idx = bisect!(lt,const X)(sorted_array, x);
    if (idx == 0)
        return false;
    
    return X[idx-1] == x;
}
