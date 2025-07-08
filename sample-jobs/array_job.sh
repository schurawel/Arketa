#!/bin/bash
#SBATCH --job-name=array_job
#SBATCH --output=array_job_%A_%a.out
#SBATCH --error=array_job_%A_%a.err
#SBATCH --time=00:10:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --partition=compute
#SBATCH --array=1-5

# Create output directory if it doesn't exist
mkdir -p ~/job_outputs
cd ~/job_outputs

echo "Array Job Example"
echo "Job Array ID: $SLURM_ARRAY_JOB_ID"
echo "Job Array Task ID: $SLURM_ARRAY_TASK_ID"
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_JOB_NODELIST"

# Define different tasks based on array index
case $SLURM_ARRAY_TASK_ID in
    1)
        echo "Task 1: Processing dataset A"
        # Simulate data processing
        for i in {1..100}; do
            echo "Processing record $i of dataset A" >> dataset_A_output.txt
            sleep 0.1
        done
        echo "Dataset A processing completed"
        ;;
    2)
        echo "Task 2: Processing dataset B"
        # Simulate data processing
        for i in {1..150}; do
            echo "Processing record $i of dataset B" >> dataset_B_output.txt
            sleep 0.05
        done
        echo "Dataset B processing completed"
        ;;
    3)
        echo "Task 3: Mathematical computation"
        # Calculate factorial
        n=20
        factorial=1
        for i in $(seq 1 $n); do
            factorial=$((factorial * i))
        done
        echo "Factorial of $n is $factorial" > factorial_result.txt
        echo "Mathematical computation completed"
        ;;
    4)
        echo "Task 4: System analysis"
        # System information gathering
        {
            echo "=== System Analysis Report ==="
            echo "Date: $(date)"
            echo "Hostname: $(hostname)"
            echo "Uptime: $(uptime)"
            echo "Disk usage:"
            df -h
            echo "Memory usage:"
            free -h
            echo "Process count: $(ps aux | wc -l)"
        } > system_analysis_report.txt
        echo "System analysis completed"
        ;;
    5)
        echo "Task 5: Log file analysis"
        # Create and analyze a mock log file
        {
            echo "INFO: Application started at $(date)"
            echo "DEBUG: Loading configuration"
            echo "INFO: Configuration loaded successfully"
            echo "WARNING: High memory usage detected"
            echo "ERROR: Connection timeout"
            echo "INFO: Retrying connection"
            echo "INFO: Connection established"
            echo "INFO: Processing complete"
        } > mock_application.log
        
        # Analyze the log
        {
            echo "=== Log Analysis Report ==="
            echo "Total lines: $(wc -l < mock_application.log)"
            echo "INFO messages: $(grep -c "INFO" mock_application.log)"
            echo "WARNING messages: $(grep -c "WARNING" mock_application.log)"
            echo "ERROR messages: $(grep -c "ERROR" mock_application.log)"
            echo "DEBUG messages: $(grep -c "DEBUG" mock_application.log)"
        } > log_analysis_report.txt
        echo "Log file analysis completed"
        ;;
    *)
        echo "Unknown task ID: $SLURM_ARRAY_TASK_ID"
        exit 1
        ;;
esac

echo "Array task $SLURM_ARRAY_TASK_ID completed successfully!"
