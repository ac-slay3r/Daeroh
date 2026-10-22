# Companion ZIP expansion fixture

`manifest_bomb.zip` is a deterministic 1,148-byte ZIP with a single `pet.json`
containing 1,048,576 ASCII spaces, compressed with DEFLATE level 9. It contains
no executable content. SHA-256:
`1fff7f7be1d0fc884c00e962403a1b2d8cba4fd9bc44d134f4fff49c1412d95b`.

Generated using Python stdlib `zipfile.ZipFile` and `ZipInfo('pet.json',
date_time=(2020, 1, 1, 0, 0, 0))`, `compress_type=ZIP_DEFLATED`,
`writestr(info, b' ' * (1024 * 1024), compresslevel=9)`.

Tests reject both the declared expansion and a copy with local/central sizes
forged to 32 bytes. The forged copy reaches the immediate output guard rather
than allocating the expanded payload first. Import tests also verify that an
existing installation and its bytes remain unchanged.
