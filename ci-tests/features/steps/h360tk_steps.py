from behave import given, when, then
import logging
from psycopg import sql

# A simple class to simulate the application code we are testing
class H360tkSteps:
    def __init__(self):
        plop  = None




@given('I create a new facility with name "{facility_name}"')
def step_impl(context, facility_name):
    pool = context.leaf_db_pool
    try:
        with pool.connection() as conn:
            with conn.cursor() as cursor:
                
                # --- Run the SELECT query ---
                select_query = "SELECT id, name FROM users WHERE id = %s;"
                cursor.execute(select_query, (1,))
                user_record = cursor.fetchone()
                print("Select Result:", user_record)
                
                # --- Run the INSERT query ---
                insert_query = "INSERT INTO users (name, email) VALUES (%s, %s);"
                cursor.execute(insert_query, ("Bob", "bob@example.com"))
                print("Insert query executed successfully")
                
                # Note: Do NOT call conn.commit() manually here. 
                # Psycopg 3's `with pool.connection()` context block manages the commit automatically 
                # as soon as execution exits this indentation block cleanly.

        print("Transaction committed automatically and connection returned to the pool.")
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        raise



@given('The following facility exists:')
def step_impl(context):
    pool = context.leaf_db_pool
    context. parent_id = None 
    context.created_hierarchy = []
    
    try:
        with pool.connection() as conn:
            with conn.cursor() as cursor:
                for row in context.table:
                    facility_name = row['name']
                    
                    # 1. Check if the tier already exists.
                    # We look up based on name and parent_id.
                    if parent_id is None:
                        select_query = "SELECT id, level FROM org_units WHERE name = %s AND parent_id IS NULL LIMIT 1;"
                        cursor.execute(select_query, (facility_name,))
                    else:
                        select_query = "SELECT id, level FROM org_units WHERE name = %s AND parent_id = %s LIMIT 1;"
                        cursor.execute(select_query, (facility_name, parent_id))
                    
                    result = cursor.fetchone()
                    
                    if result:
                        current_id = result[0]
                        current_level = result[1]
                    else:
                        # 2. If it doesn't exist, we INSERT it.
                        # Instead of calculating 'level' in Python, we query the parent's level 
                        # directly in the SQL statement. If parent_id is NULL, it falls back to 1.
                        insert_query = """
                            INSERT INTO org_units (name, parent_id, level) 
                            VALUES (
                                %s, 
                                %s, 
                                COALESCE((SELECT level + 1 FROM org_units WHERE id = %s), 1)
                            ) 
                            RETURNING id, level;
                        """
                        cursor.execute(insert_query, (facility_name, parent_id, parent_id))
                        
                        inserted_result = cursor.fetchone()
                        current_id = inserted_result[0]
                        current_level = inserted_result[1]
                    
                    # Save the real database values to the context tracking list
                    context.created_hierarchy.append({
                        "id": current_id,
                        "name": facility_name,
                        "parent_id": parent_id,
                        "level": current_level
                    })
                    
                    # Move down to the next child item
                    parent_id = current_id
                    
    except Exception as e:
        raise AssertionError(f"Failed to process facility hierarchy idempotently: {e}")




@given('A top level Org Unit exists for the current run')
def add_test_top_level_facility(context):

    logging.warn('Sample dict log: %s', context)
    context.current_facility_id  = None
    context.created_hierarchy = []
    add_facility(context, context.run_id)




@given('An org unit exists in the current org unit with name {name_param}')
def add_facility(context, name_param):
    pool = context.leaf_db_pool
    # 2. Get the current parent ID from context
    parent_id = context.current_facility_id
    try:
        with pool.connection() as conn:
            with conn.cursor() as cursor:
                facility_name = name_param

                print("########################################", flush=True)
                print("########################################", flush=True)
                print("creating one Facility", parent_id, flush=True)
                print("parent_id", parent_id,flush=True)
                print("########################################", flush=True)
                print("########################################", flush=True)

                
                # 1. Check if the tier already exists.
                # We look up based on name and parent_id.
                if parent_id is None:
                    select_query = "SELECT id, level FROM org_units WHERE name = %s AND parent_id IS NULL LIMIT 1;"
                    cursor.execute(select_query, (facility_name,))
                else:
                    select_query = "SELECT id, level FROM org_units WHERE name = %s AND parent_id = %s LIMIT 1;"
                    cursor.execute(select_query, (facility_name, parent_id))
                
                result = cursor.fetchone()
                
                if result:
                    current_id = result[0]
                    current_level = result[1]
                else:
                    # 2. If it doesn't exist, we INSERT it.
                    # Instead of calculating 'level' in Python, we query the parent's level 
                    # directly in the SQL statement. If parent_id is NULL, it falls back to 1.
                    insert_query = """
                        INSERT INTO org_units (name, parent_id, level) 
                        VALUES (
                            %s, 
                            %s, 
                            COALESCE((SELECT level + 1 FROM org_units WHERE id = %s), 1)
                        ) 
                        RETURNING id, level;
                    """
                    cursor.execute(insert_query, (facility_name, parent_id, parent_id))
                    
                    inserted_result = cursor.fetchone()
                    current_id = inserted_result[0]
                    current_level = inserted_result[1]
                
                # Save the real database values to the context tracking list
                context.created_hierarchy.append({
                    "id": current_id,
                    "name": facility_name,
                    "parent_id": parent_id,
                    "level": current_level
                })
                
                # Move down to the next child item
                context.current_facility_id = current_id
                    
    except Exception as e:
        raise AssertionError(f"Failed to process facility hierarchy idempotently: {e}")


@given('That Facility has a patient with the following details')
def step_impl(context):
    # 1. Ensure the parent facility context exists
    facility_id = getattr(context, 'current_facility_id', None)
    if not facility_id:
        raise RuntimeError("State Error: 'current_facility_id' is missing from the test context.")
    pool = context.leaf_db_pool
    try:
        with pool.connection() as conn:
            with conn.cursor() as cursor:
                # Iterate over the row(s) provided in the Gherkin table
                for row in context.table:
                    # Convert the row into a standard dictionary
                    row_data = {key: row[key] for key in row.headings}
                    
                    # Force inject the facility_id from context
                    row_data['org_unit_id'] = facility_id
                                        
                    columns = []
                    query_values = []
                    bound_values = []
                    columns.append(sql.Identifier('patient_id'))
                    query_values.append(sql.SQL("nextval({})").format(sql.Literal("patient_diagnoses_id_seq")))
                    
                    if 'registration_date' not in row_data:
                        columns.append(sql.Identifier('registration_date'))
                        query_values.append(sql.SQL('CURRENT_TIMESTAMP'))

                    for key, val in row_data.items():
                        
                        if isinstance(val, str) and val.strip() == "":
                            continue  # Skip blank optional fields
                        columns.append(sql.Identifier(key))
                        # We append a placeholder object to represent %s in the final values list
                        query_values.append(sql.Placeholder())
                        bound_values.append(val)

                    query = sql.SQL("""
                        INSERT INTO patients ({fields})
                        VALUES ({values_clause})
                        RETURNING patient_id;
                    """).format(
                        fields=sql.SQL(', ').join(columns),
                        values_clause=sql.SQL(', ').join(query_values)
                    )

                    raw_sql_string = query.as_string(cursor)
                    print(raw_sql_string)

                    # 4. Execute the dynamic query safely against the DB
                    cursor.execute(query, bound_values)
                    context.current_patient_id = cursor.fetchone()[0]
                    
    except Exception as e:
        raise RuntimeError(f"Dynamic database insertion failed for patients table: {e}")

