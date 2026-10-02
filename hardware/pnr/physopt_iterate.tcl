# @brief  Squeeze the last slack out of an ALREADY ROUTED design with extra post-route
#         phys_opt_design passes. Generalized from build-28's copy (which hardcoded that build).
#
# WHY THIS WORKS ON build-29 (and only bought +0.021 on build-28). phys_opt_design repairs timing
# LOCALLY on a routed design -- replicating high-fanout drivers so each copy sits near its loads,
# retiming registers across logic, re-placing individual critical cells, then re-routing just what
# it touched. Which repair pays depends on WHY the path is slow:
#   build-28 SpreadSLLs (-0.657): 15 levels, 47.8% LOGIC  -> logic-depth bound. Retiming led, and the
#                                 whole ladder only recovered +0.021 (CARRY8 chains already tight).
#   build-29 HBM-out    (-0.553):  7 levels, 84.3% ROUTE, cluster fanouts 52..234 -> DRIVER-TOO-FAR
#                                 bound. REPLICATION is the matching repair, so it leads here.
# Hence the directive order below is deliberately fanout/replication-first for this build.
#
# METHOD. Each attempt RE-OPENS the best checkpoint so far, applies ONE directive, and is kept only if
# it improves setup WITHOUT breaking hold. Re-opening is what makes a failed attempt free instead of
# destructive (phys_opt_design mutates the design in place).
#
# HOLD IS A REAL RISK: replication and retiming both trade setup for hold, and this design sits at
# WHS +0.004 ns. An attempt that improves WNS but drives WHS negative is REJECTED -- a hold violation
# is a broken bitstream, not a tradeoff.
#
# Usage:  cp hardware/pnr/physopt_iterate.tcl hardware/build-NN/ && cd hardware/build-NN
#         export TERM=xterm
#         vivado -mode batch -source physopt_iterate.tcl                      # defaults below
#         vivado -mode batch -source physopt_iterate.tcl -tclargs "<DIRECTIVES>" <IN_DCP> <OUT_TAG>

if {[catch {

# Run from inside the routed build directory (hardware/build-NN), which holds base.tcl.
source [file join [pwd] base.tcl]

# Fanout/replication first -- see the header. Explore last as a catch-all.
set dir_list "AggressiveFanoutOpt AlternateReplication AddRetime AlternateFlowWithRetiming Explore"
set in_dcp   "shell_routed"          ;# build-29's main flow checkpoint (untagged)
set out_tag  "b29"

if {$argc >= 1 && [lindex $argv 0] ne ""} { set dir_list [lindex $argv 0] }
if {$argc >= 2 && [lindex $argv 1] ne ""} { set in_dcp   [lindex $argv 1] }
if {$argc >= 3 && [lindex $argv 2] ne ""} { set out_tag  [lindex $argv 2] }
set_param general.maxThreads 8

proc slacks {} {
    set s [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]]
    set h [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -hold]  0]]
    return [list $s $h]
}

set best_dcp "$dcp_dir/$in_dcp.dcp"
if {![file exists $best_dcp]} { error "input checkpoint not found: $best_dcp" }

open_checkpoint $best_dcp
lassign [slacks] best_wns best_whs
close_project
set start_wns $best_wns
puts "[color $clr_cmplt "** BASELINE ($in_dcp): WNS = $best_wns   WHS = $best_whs"]"
puts "[color $clr_flow  "** ladder: $dir_list"]"

set applied {}
foreach d $dir_list {
    set tag "${out_tag}_po_[string tolower $d]"
    puts "[color $clr_flow "** ATTEMPT: phys_opt_design -directive $d   (best so far: WNS $best_wns)"]"

    open_checkpoint $best_dcp
    if {[catch {phys_opt_design -directive $d} e]} {
        puts "[color $clr_error "** $d FAILED: $e"]" ; close_project ; continue
    }
    lassign [slacks] wns whs
    puts "[color $clr_cmplt "** $d -> WNS = $wns   WHS = $whs   (best was $best_wns)"]"

    if {$whs < 0} {
        puts "[color $clr_error "** REJECTED ($d): hold BROKEN (WHS $whs) -- setup gain is not usable"]"
        close_project ; continue
    }
    if {$wns > $best_wns} {
        write_checkpoint -force "$dcp_dir/shell_routed_$tag.dcp"
        report_timing_summary -file "$rprt_dir/shell_timing_summary_$tag.rpt"
        report_timing -max_paths 1000 -sort_by group -file "$rprt_dir/shell_timing_worst_$tag.rpt"
        set best_dcp "$dcp_dir/shell_routed_$tag.dcp"
        set best_wns $wns ; set best_whs $whs
        lappend applied $d
        puts "[color $clr_cmplt "** KEPT ($d). new best WNS = $best_wns"]"
    } else {
        puts "[color $clr_rest "** discarded ($d): no setup gain"]"
    }
    close_project
}

puts "[color $clr_cmplt "** ================ LADDER RESULT ================"]"
puts "[color $clr_cmplt "** start WNS = $start_wns  ->  best WNS = $best_wns   WHS = $best_whs"]"
puts "[color $clr_cmplt "** directives kept (in order): $applied"]"
puts "[color $clr_cmplt "** best checkpoint: $best_dcp"]"

# Write the bitstream from the WINNER as soon as the ladder ends. build-28's ladder crashed on its 3rd
# attempt and never reached its (end-of-script) write_bitstream, so a good -0.636 design existed only
# as a checkpoint. Doing it here, right after the summary, is cheap insurance (~15 min).
if {$best_wns > $start_wns} {
    open_checkpoint $best_dcp
    if {[catch {
        write_bitstream -force "$bit_dir/cyt_top_${out_tag}_po.bit"
        puts "[color $clr_cmplt "** bitstream: $bit_dir/cyt_top_${out_tag}_po.bit"]"
    } e]} { puts "** (write_bitstream skipped: $e)" }
    close_project
} else {
    puts "[color $clr_rest "** no improvement over $start_wns -- no bitstream written"]"
}

} errorstring]} {
    puts "** CERR: $errorstring"
    exit 1
}
exit 0
