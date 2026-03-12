simSetSimulator "-vcssv" -exec "./build/cpu.simv" -args \
           "+MEMORY=programs/mem/simple.mem +OUTPUT=output/verdi_output" \
           -uvmDebug on -simDelim
debImport "-i" "-simflow" "-dbdir" "./build/cpu.simv.daidir"
srcTBInvokeSim
verdiSetActWin -dock widgetDock_<Member>
verdiSetActWin -dock widgetDock_MTB_SOURCE_TAB_1
srcHBSelect "testbench.verisimpleV" -win $_nTrace1
srcSetScope "testbench.verisimpleV" -delim "." -win $_nTrace1
verdiSetActWin -dock widgetDock_<Inst._Tree>
srcHBSelect "testbench.verisimpleV" -win $_nTrace1
srcHBSelect "testbench.verisimpleV.fetch_buffer_0" -win $_nTrace1
srcSetScope "testbench.verisimpleV.fetch_buffer_0" -delim "." -win $_nTrace1
srcHBSelect "testbench.verisimpleV.fetch_buffer_0" -win $_nTrace1
srcSignalViewSelect "testbench.verisimpleV.fetch_buffer_0.mispredicted"
verdiSetActWin -dock widgetDock_<Signal_List>
srcSignalViewSelectAll -curPage
wvCreateWindow
srcSignalViewAddSelectedToWave -clipboard
wvDrop -win $_nWave3
verdiSetActWin -win $_nWave3
srcTBRunSim
srcTBSimBreak
verdiFindBar -hide -win nWave_3
srcSignalView -off
verdiDockWidgetMaximize -dock windowDock_nWave_3
wvSetPosition -win $_nWave3 {("G1" 5)}
wvExpandBus -win $_nWave3
wvSetPosition -win $_nWave3 {("G1" 19)}
wvSelectSignal -win $_nWave3 {( "G1" 5 )} 
wvSelectSignal -win $_nWave3 {( "G1" 6 )} 
wvSelectSignal -win $_nWave3 {( "G1" 9 )} 
wvSetPosition -win $_nWave3 {("G1" 9)}
wvExpandBus -win $_nWave3
wvSetPosition -win $_nWave3 {("G1" 21)}
