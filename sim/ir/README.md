Unit tests of the IR receiver and the modem UART against the webtv-bridge JS classes.

    node irref.mjs > reft.txt         # JS SoloIr: key events -> TRANS_DATA reads (time, value; also events.txt)
    node uartref.mjs > uart_ref.txt   # JS Uart16550: random op script (also writes uart_ops.txt)
    for f in ../../rtl/webtv/webtv_bustick.vhd ../../rtl/webtv/webtv_sdpram.vhd ../../rtl/webtv/webtv_ir.vhd \
             ../../rtl/webtv/webtv_uart16550.vhd tb_ir.vhd tb_uart.vhd; do ghdl -a --std=08 -frelaxed --workdir=. $f; done
    ghdl -e --std=08 -frelaxed --workdir=. tb_ir && ./tb_ir      # -> rtl.txt  (read time, value)
    ghdl -e --std=08 -frelaxed --workdir=. tb_uart && ./tb_uart  # -> uart_rtl.txt
    diff uart_ref.txt uart_rtl.txt
    diff <(cut -d' ' -f2 reft.txt | sed 's/^.//') <(cut -d' ' -f2 rtl.txt | tr A-F a-f | sed 's/^0*//; s/^.//')

IR: the level/ticks sequence must be identical; the ready count (top nibble) may differ at a read that falls
within one 15 us tick of a run's end (the RTL starts packets on tick boundaries).
