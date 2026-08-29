# ============================================================================
# Safety-Critical VHDL Coding Standard
# ============================================================================
# ISO 26262 Part 7: Guidelines for Hardware Safety Requirements
# Based on SafeVHDL, MISRA-VHDL, and ISO 26262 best practices
# Document ID: STD-VHDL-001
# Revision: 1.0
# ============================================================================

## 1. SCOPE
This standard applies to all VHDL source files in the lockstep-rv32-soc
project. It defines mandatory and advisory rules for safety-critical hardware
design targeting ASIL-D compliance.

---

## 2. MANDATORY RULES (M-Series)

### 2.1 Design Rules

| Rule | Description                              | Severity |
|------|------------------------------------------|----------|
| M-01 | All processes must have explicit sensitivity lists | Mandatory |
| M-02 | No inferred latches — all combinational processes must have default assignments | Mandatory |
| M-03 | All FSMs must use explicit safe-state encoding (t_safe_state) | Mandatory |
| M-04 | Reset must be synchronous with explicit polarity | Mandatory |
| M-05 | No mixed-edge clocking in a single process | Mandatory |
| M-06 | All signals must have explicit initialization | Mandatory |
| M-07 | No use of `std_logic_arith` or `std_logic_unsigned` — use `numeric_std` only | Mandatory |
| M-08 | All generics must have default values | Mandatory |
| M-09 | No unconstrained arrays in port declarations | Mandatory |
| M-10 | All safety-critical processes must have traceability attributes | Mandatory |

### 2.2 Naming Conventions

| Prefix | Meaning                      | Example            |
|--------|------------------------------|--------------------|
| `r_`   | Registered (clocked) signal  | `r_counter`        |
| `w_`   | Combinational (wire) signal  | `w_mismatch`       |
| `v_`   | Process-local variable       | `v_parity_count`   |
| `C_`   | Constant                     | `C_WD_MAX_COUNT`   |
| `G_`   | Generic                      | `G_DATA_WIDTH`     |

### 2.3 Safety Annotations

Every RTL file must include:
```vhdl
-- ISO 26262 Automated Traceability Attributes
attribute requirement_id : string;
attribute requirement_id of rtl : architecture is "TSR_<BLOCK>_001";
```

---

## 3. ADVISORY RULES (A-Series)

| Rule | Description                              | Severity |
|------|------------------------------------------|----------|
| A-01 | Prefer `std_logic_vector` over `bit_vector` | Advisory |
| A-02 | Use `rising_edge()` instead of `clk'event and clk = '1'` | Advisory |
| A-03 | FSM states should have Hamming distance >= 4 | Advisory |
| A-04 | Avoid `others =>` in record initialization (GHDL compatibility) | Advisory |
| A-05 | Prefer explicit type conversion over implicit | Advisory |
| A-06 | Add formal verification assertions for safety properties | Advisory |
| A-07 | Use `severity note` for debug, `severity error` for safety violations | Advisory |
| A-08 | Comment every process with its safety role | Advisory |

---

## 4. FSM ENCODING STANDARD

### 4.1 Safe State Encoding
All FSMs use one-hot encoding with high Hamming distance:
```vhdl
type t_safe_state is (
    ST_SYSTEM_OK       => "10001",  -- Hamming weight 2
    ST_FAULT_TRIPPED   => "01110"   -- Hamming weight 3, distance 4 from OK
);
```

### 4.2 Illegal State Handling
Any unencoded state must transition to fault:
```vhdl
when others =>
    w_next_state <= ST_FAULT_TRIPPED;
```

---

## 5. CLOCK DOMAIN RULES

| Rule | Description                              |
|------|------------------------------------------|
| CD-01 | Each process must use exactly one clock  |
| CD-02 | Cross-domain synchronization requires explicit synchronizer |
| CD-03 | Watchdog must use independent clock source |
| CD-04 | No asynchronous reset across clock domains |

---

## 6. VERIFICATION REQUIREMENTS

| Req | Description                              |
|-----|------------------------------------------|
| V-01 | Every safety block must have a functional testbench |
| V-02 | Every safety block must have fault injection tests |
| V-03 | Formal assertions must verify safety properties |
| V-04 | Testbenches must use VUnit `check()` API |
| V-05 | Simulation must pass with GHDL mcode backend |

---

## 7. STATIC ANALYSIS CHECKLIST

Before committing VHDL changes, verify:
- [ ] No inferred latches (SafeVHDL clean)
- [ ] No incomplete sensitivity lists
- [ ] No mixed clock edges
- [ ] All signals initialized
- [ ] Traceability attributes present
- [ ] Naming conventions followed
- [ ] FSM encoding uses t_safe_state
- [ ] Formal assertions added/updated
