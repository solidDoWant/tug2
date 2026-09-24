#!/usr/bin/env python3
"""
MySQL to PostgreSQL Loadout Migration Script

Converts old MySQL saveloadout dump to new PostgreSQL loadouts format.
- Filters for server_id = 1 only
- Pivots one-row-per-item to one-row-per-player-class
- Aggregates items into semicolon-separated lists
- Generates bulk INSERT with ON CONFLICT handling
"""

import re
import sys
from collections import defaultdict
from typing import Dict, List, Set, Tuple


class LoadoutMigrator:
    def __init__(self, input_file: str, output_file: str):
        self.input_file = input_file
        self.output_file = output_file
        self.loadouts: Dict[Tuple[int, str], Dict[str, List[str]]] = defaultdict(
            lambda: {"gear": [], "primary": [], "secondary": [], "explosive": []}
        )

    def parse_mysql_insert(self, line: str) -> List[Tuple]:
        """
        Parse MySQL INSERT statement and extract values.
        Returns list of tuples: (server_id, steamid, classname, type, itemid)
        
        Expected format: INSERT INTO `saveloadout` VALUES (id,server_id,steamid,'classname','type','itemid')
        """
        # Match INSERT INTO with VALUES - handle multi-line
        if 'INSERT INTO' not in line and 'saveloadout' not in line:
            return []
        
        # Parse individual value tuples: (id, server_id, steamid, classname, type, itemid)
        # Handle both NULL and quoted strings, escape sequences in strings
        # Pattern matches: (digits,digits,digits,'string','string','string' or NULL)
        row_pattern = r"\((\d+),(\d+),(\d+),'([^']*)','([^']*)',(?:'([^']*)'|NULL)\)"
        rows = re.findall(row_pattern, line)
        
        results = []
        for row in rows:
            id_val, server_id, steamid, classname, type_val, itemid = row
            server_id = int(server_id)
            steamid = int(steamid)
            
            # Filter for server_id = 1 only
            if server_id != 1:
                continue
            
            # Skip if itemid is empty or None
            if not itemid:
                continue
            
            results.append((server_id, steamid, classname, type_val, itemid))
        
        return results

    def map_type_to_column(self, type_val: str) -> str:
        """
        Map old 'type' field to new column name.
        """
        # The old system might use variations, normalize them
        type_lower = type_val.lower().strip()
        
        # Map to new column names
        if type_lower in ("gear", "gear_slot"):
            return "gear"
        elif type_lower in ("primary", "primary_weapon"):
            return "primary"
        elif type_lower in ("secondary", "secondary_weapon"):
            return "secondary"
        elif type_lower in ("explosive", "explosives", "explosive_weapon"):
            return "explosive"
        else:
            # Log unknown types but attempt to use as-is
            print(f"Warning: Unknown type '{type_val}', using as column name", file=sys.stderr)
            return type_lower

    def process_file(self):
        """
        Read MySQL dump and aggregate loadouts by player/class.
        """
        print(f"Reading MySQL dump from: {self.input_file}", file=sys.stderr)
        
        line_count = 0
        insert_count = 0
        record_count = 0
        
        with open(self.input_file, 'r', encoding='utf-8') as f:
            for line in f:
                line_count += 1
                
                # Only process INSERT statements
                if not line.strip().upper().startswith('INSERT'):
                    continue
                
                insert_count += 1
                rows = self.parse_mysql_insert(line)
                
                for server_id, steamid, classname, type_val, itemid in rows:
                    record_count += 1
                    
                    # Skip empty itemids
                    if not itemid or itemid.strip() == '':
                        continue
                    
                    # Map type to column
                    column = self.map_type_to_column(type_val)
                    
                    # Aggregate by (steamid, classname)
                    key = (steamid, classname)
                    
                    # Append itemid to appropriate slot list
                    if column in self.loadouts[key]:
                        self.loadouts[key][column].append(itemid)
                    else:
                        print(f"Warning: Unmapped column '{column}' for type '{type_val}'", file=sys.stderr)
        
        print(f"Processed {line_count} lines, {insert_count} INSERT statements, {record_count} records for server_id=1", file=sys.stderr)
        print(f"Found {len(self.loadouts)} unique player/class combinations", file=sys.stderr)

    def format_postgres_value(self, items: List[str]) -> str:
        """
        Format list of items as PostgreSQL value (semicolon-separated or NULL).
        """
        if not items or len(items) == 0:
            return "NULL"
        
        # Join with semicolons and escape single quotes
        joined = ";".join(items)
        escaped = joined.replace("'", "''")
        return f"'{escaped}'"

    def generate_postgres_insert(self):
        """
        Generate PostgreSQL bulk INSERT statement with ON CONFLICT handling.
        """
        print(f"Writing PostgreSQL dump to: {self.output_file}", file=sys.stderr)
        
        with open(self.output_file, 'w', encoding='utf-8') as f:
            # Write header
            f.write("-- =====================================================\n")
            f.write("-- Migrated Loadout Data from MySQL saveloadout table\n")
            f.write(f"-- Source: {self.input_file}\n")
            f.write("-- Filtered for server_id = 1 only\n")
            f.write(f"-- Total loadouts: {len(self.loadouts)}\n")
            f.write("-- =====================================================\n\n")
            
            if len(self.loadouts) == 0:
                f.write("-- No loadouts found for server_id = 1\n")
                return
            
            # Begin transaction
            f.write("BEGIN;\n\n")
            
            # Write INSERT statement with all values
            f.write("INSERT INTO loadouts (steam_id, class_template, gear, primary_weapon, secondary_weapon, explosive)\nVALUES\n")
            
            values = []
            for (steamid, classname), slots in sorted(self.loadouts.items()):
                gear = self.format_postgres_value(slots["gear"])
                primary = self.format_postgres_value(slots["primary"])
                secondary = self.format_postgres_value(slots["secondary"])
                explosive = self.format_postgres_value(slots["explosive"])
                
                # Escape class template single quotes
                classname_escaped = classname.replace("'", "''")
                
                value_line = f"    ({steamid}, '{classname_escaped}', {gear}, {primary}, {secondary}, {explosive})"
                values.append(value_line)
            
            # Write all values with commas
            f.write(",\n".join(values))
            f.write("\n")
            
            # ON CONFLICT clause - update if record already exists
            f.write("ON CONFLICT (steam_id, class_template) DO UPDATE SET\n")
            f.write("    gear = EXCLUDED.gear,\n")
            f.write("    primary_weapon = EXCLUDED.primary_weapon,\n")
            f.write("    secondary_weapon = EXCLUDED.secondary_weapon,\n")
            f.write("    explosive = EXCLUDED.explosive,\n")
            f.write("    updated_at = CURRENT_TIMESTAMP,\n")
            f.write("    update_count = loadouts.update_count + 1;\n\n")
            
            # Commit transaction
            f.write("COMMIT;\n\n")
            
            # Write summary
            f.write(f"-- Successfully migrated {len(self.loadouts)} loadouts\n")
        
        print(f"Migration complete! Generated {len(self.loadouts)} loadout records", file=sys.stderr)

    def run(self):
        """Execute the full migration process."""
        try:
            self.process_file()
            self.generate_postgres_insert()
            print("\n✓ Migration successful!", file=sys.stderr)
            return 0
        except Exception as e:
            print(f"\n✗ Migration failed: {e}", file=sys.stderr)
            import traceback
            traceback.print_exc()
            return 1


def main():
    if len(sys.argv) != 3:
        print("Usage: migrate_loadouts.py <input_mysql_dump.sql> <output_postgres_dump.sql>")
        print("\nExample:")
        print("  ./migrate_loadouts.py old_loadouts.sql new_loadouts.sql")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    migrator = LoadoutMigrator(input_file, output_file)
    sys.exit(migrator.run())


if __name__ == "__main__":
    main()
