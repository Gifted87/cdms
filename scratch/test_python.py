import os
import sys
from math import sqrt

class MatrixProcessor:
    """Processes matrices."""
    def __init__(self, data):
        self.data = data
        
    def process(self):
        print(f"Processing with sqrt: {sqrt(16)}")
        return os.path.join("/tmp", "result.txt")

def main():
    proc = MatrixProcessor([1,2,3])
    proc.process()

if __name__ == "__main__":
    main()
