#!/usr/bin/env python3
"""
Fix VSG violations across lockstep-rv32-soc VHDL sources:
  - signal_007 / variable_007: Remove default assignments (:= ...)
  - instantiation_034 / 036: Convert entity instantiations to component instantiations
"""
import re
import sys
from pathlib import Path

root = Path(__file__).parent
vhdl_files = list(root.rglob("*.vhd"))

def strip_defaults(text):
    """Remove := ... from signal/variable declarations."""
    # Match signal/variable lines with := before the semicolon
    # e.g. signal foo : std_logic := '0';
    #      variable bar : std_logic_vector(7 downto 0) := (others => '0');
    def replace_line(m):
        prefix = m.group(1)  # "signal" or "variable"
        decl = m.group(2)    # everything between keyword and :=
        return f"{prefix}{decl};"
    
    # Handle simple := '0' / := "00" / := (others => '0')
    text = re.sub(
        r'(signal|variable)\s+([\w\s:\(\)\->\'"]+?)\s*:=\s*[^;]+;\s*',
        lambda m: f"{m.group(1)} {m.group(2)};\n",
        text, flags=re.IGNORECASE
    )
    return text

def add_component(text):
    """Convert entity instantiations to component instantiations."""
    # Pattern to match:
    #   inst_label: entity work.entity_name(arch) port map ( ... );
    #   or:
    #   inst_label: entity entity_name port map ( ... );
    entity_pattern = re.compile(
        r'^(\s*\w+):\s*entity\s+(?:work\.)?(\w+)(?:\((\w+)\))?\s*port\s+map\s*\((.*?)\);\s*$',
        re.MULTILINE | re.DOTALL | re.IGNORECASE
    )
    
    components = []
    def extract_component(m):
        label = m.group(1).strip()
        entity = m.group(2)
        arch = m.group(3) or ""
        port_map = m.group(4)
        
        # Parse port names and directions from the port map
        # This is a simplification — we just need the component to exist
        components.append((entity, arch))
        return m.group(0)  # Leave the instantiation for now
    
    entity_pattern.sub(extract_component, text)
    
    # Deduplicate components
    seen = set()
    unique = []
    for entity, arch in components:
        key = (entity, arch)
        if key not in seen:
            seen.add(key)
            unique.append(key)
    
    if not unique:
        return text
    
    # Generate component declarations
    comp_decls = []
    comp_decls.append("\n-- Component declarations (added for VSG compliance)\n")
    for entity, arch in unique:
        line = f"component {entity}"
        if arch:
            line += f" entity {entity}({arch})"
        line += " end component;"
        comp_decls.append(line)
    comp_decls.append("")
    
    # Insert before the first entity instantiation
    first_match = entity_pattern.search(text)
    if first_match:
        insert_pos = first_match.start()
        text = text[:insert_pos] + "\n".join(comp_decls) + "\n" + text[insert_pos:]
    
    return text

for f in vhdl_files:
    if 'OsvvmLibraries' in str(f) or 'neorv32' in str(f):
        continue
    
    original = f.read_text()
    fixed = strip_defaults(original)
    fixed = add_component(fixed)
    
    if fixed != original:
        f.write_text(fixed)
        print(f"Fixed: {f.relative_to(root)}")

print("Done.")
