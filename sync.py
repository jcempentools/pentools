import os
import sys
import shutil
import re
import xxhash
from tqdm import tqdm

__ignored = f"\\.(git(\\{os.sep}|$)|(log|tmp)$)"

print(" ")

if len(sys.argv) != 2:
    print ("Path destino não fornecida.")
    exit(1)

destination_path = os.path.normpath(sys.argv[1]).rstrip(os.path.sep)
origin_path = os.path.normpath(os.getcwd()).rstrip(os.path.sep)

if not os.path.exists(destination_path):
    print ("Path destino não exi    ste.")
    exit

if not os.path.isdir(destination_path):
    print ("Path destino não é uma pasta.")
    exit    

def hash_file(filename):
    """
    Calculates the xxHash (64-bit) of a file.

    Args:
        filename (str): The path to the file.

    Returns:
        str: The hexadecimal representation of the xxHash, or None if an error occurs.
    """
    try:
        with open(filename, 'rb') as file:
            hasher = xxhash.xxh3_64()
            while True:
                chunk = file.read(4096)  # Read in 4KB chunks
                if not chunk:
                    break
                hasher.update(chunk)
            return hasher.hexdigest()
    except FileNotFoundError:        
        return None
    except Exception as e:
         print(f"An error occurred: {e}")
         return None
       
def copy_file_sync(src, dst):
    """
    Copies a file from src to dst and forces synchronization to disk.

    Args:
        src (str): The path to the source file.
        dst (str): The path to the destination file.
    """        
    h_from = "1"
    h_to = ""    

    if os.path.exists(dst):               
        h_from = hash_file(src)
        h_to = hash_file(dst)

    if (h_from != h_to):
        file_size = os.path.getsize(src)
        print("\n", end='\r')
        
        with open(src, 'rb') as f_in, open(dst, 'wb') as f_out:
            with tqdm(desc=os.path.basename(dst), total=file_size, unit='B', unit_scale=True, unit_divisor=1024) as bar:
                for chunk in iter(lambda: f_in.read(4096), b""):
                    f_out.write(chunk)
                    bar.update(len(chunk))
                               
        print("\n", end='\r')

def recursive_directory_iteration(directory, action):
    for root, subdirectories, files in os.walk(directory):                
        for file in files:            
            action(os.path.join(root, file))

        for subdirectory in subdirectories:             
            if (subdirectory != "" and subdirectory != "."):
                action(os.path.join(root, subdirectory))                       
                recursive_directory_iteration(os.path.join(root, subdirectory), action)

def origin_to_destination(path):        
    global __ignored

    if bool(re.search(__ignored, path)):
        return 0

    global destination_path
    global origin_path    
    
    print(" "*os.get_terminal_size().columns, end="\r")
    print(f"- Copiar? '{path.replace(destination_path, '').replace(origin_path, '')}'", end="\r")

    dest_path = path.replace(origin_path, destination_path)    

    if os.path.exists(dest_path):        
        if not os.path.isdir(dest_path):
            copy_file_sync(path, dest_path)
    else:
        if os.path.isdir(path):
            os.makedirs(dest_path, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(dest_path), exist_ok=True)

        copy_file_sync(path, dest_path)

def remove_from_destination(path):
    global __ignored

    if bool(re.search(__ignored, path)):
        return 0    

    global destination_path
    global origin_path    

    from_path = path.replace(destination_path, origin_path)        

    if not os.path.exists(from_path):   
        print(" "*os.get_terminal_size().columns, end="\r")
        print(f"-> Removendo '{path}'", end="\r")

        if os.path.isdir(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
   
recursive_directory_iteration(origin_path, origin_to_destination)

print(" ")
print("Limpando...")
print(" ")

recursive_directory_iteration(destination_path, remove_from_destination)

print(" ")
print("Sincronização concluída.")
print(" ")