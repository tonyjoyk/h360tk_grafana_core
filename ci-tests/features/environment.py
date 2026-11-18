import psycopg
import time
from psycopg_pool import ConnectionPool

def before_all(context):


    ## The Id of the Run
    context.run_id=f"test_{int(time.time())}";
    
    ## run state
    context.current_facility_id=None


    ##
    ## The connection pools
    ##
    print("Initializing PostgreSQL Connection Pool...")
    try:

        leaf_db_config = {
            "host": "db-leaf",
            "dbname": "heart360tk_database",
            "user": "heart360tk",
            "password": "YmE4ZTk0OGI0OTNmNGU5YmFjZDY1YTA0",
            "port": 5432  # Can be an integer or a string "5432"
        }


        # Initialize a ThreadedConnectionPool (best for testing environments)
        context.leaf_db_pool = ConnectionPool(
            kwargs=leaf_db_config,   # Pass the dictionary here
            min_size=10,
            max_size=10,
            open=True
        )
        context.leaf_db_pool.wait()
        print("PostgreSQL Connection Pool initialized successfully.")

    except (Exception, psycopg2.DatabaseError) as error:
        print(f"Error while connecting to PostgreSQL: {error}")
        raise error





def after_all(context):
    """
    Runs once after all features and steps have completed.
    Closes all connections in the pool.
    """
    print("Stopping Connection Pools Connection Pool...")
    
    if hasattr(context, 'db_pool') and context.db_pool:
        # Close all connections held by the pool to prevent resource leaks
        context.db_pool.closeall()
        print("PostgreSQL Connection Pool closed.")