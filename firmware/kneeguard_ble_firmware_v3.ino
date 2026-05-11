/***************************************************************************
* KneeGuard - 膝关节运动监测系统 v7.1 (FreeRTOS + BLE传输 + Flush机制)
* 
* 特性：
* 1. FreeRTOS双任务架构 - 采样任务绝不阻塞
* 2. 环形缓冲区 - 线程安全，自动覆盖
* 3. BLE传输数据 - 通过手机接收
* 4. BLE接收控制命令 - START/STOP/MODE
* 5. 100Hz精确采样
* 6. 停止时自动发送剩余数据 (NEW!)
***************************************************************************/

#include <Wire.h>
#include <ICM20948_WE.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>

// ==========================================================================
// 配置 - 修改这里
// ==========================================================================
const char* deviceId = "knee01";  // 设备ID

// ==========================================================================
// 常量定义
// ==========================================================================
#define DEVICE_NAME "KneeGuard-v7"
#define SERVICE_UUID "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define RX_UUID "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define TX_UUID "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

#define ADDR_THIGH 0x68
#define ADDR_SHANK 0x69
#define SAMPLE_INTERVAL_MS 5  // 200Hz
#define BATCH_SIZE 200          // 每250个样本上传一次
#define RING_BUFFER_SIZE 2000   // 环形缓冲区

// ==========================================================================
// 数据结构
// ==========================================================================
struct Sample {
    uint64_t t_us;
    float ax, ay, az;
    float gx, gy, gz;
    uint8_t sensor_id;  // 1=thigh, 2=shank
};

// 环形缓冲区
class RingBuffer {
private:
    Sample buffer[RING_BUFFER_SIZE];
    volatile int head;
    volatile int tail;
    SemaphoreHandle_t mutex;
    
public:
    RingBuffer() : head(0), tail(0) {
        mutex = xSemaphoreCreateMutex();
    }
    
    bool push(const Sample& sample) {
        if (xSemaphoreTake(mutex, pdMS_TO_TICKS(10)) == pdTRUE) {
            int next = (head + 1) % RING_BUFFER_SIZE;
            if (next == tail) {
                tail = (tail + 1) % RING_BUFFER_SIZE;  // 覆盖旧数据
            }
            buffer[head] = sample;
            head = next;
            xSemaphoreGive(mutex);
            return true;
        }
        return false;
    }
    
    bool pop(Sample* sample) {
        if (xSemaphoreTake(mutex, pdMS_TO_TICKS(10)) == pdTRUE) {
            if (head == tail) {
                xSemaphoreGive(mutex);
                return false;
            }
            *sample = buffer[tail];
            tail = (tail + 1) % RING_BUFFER_SIZE;
            xSemaphoreGive(mutex);
            return true;
        }
        return false;
    }
    
    int count() {
        int cnt = 0;
        if (xSemaphoreTake(mutex, pdMS_TO_TICKS(10)) == pdTRUE) {
            cnt = (head - tail + RING_BUFFER_SIZE) % RING_BUFFER_SIZE;
            xSemaphoreGive(mutex);
        }
        return cnt;
    }
    
    void clear() {
        if (xSemaphoreTake(mutex, pdMS_TO_TICKS(10)) == pdTRUE) {
            head = tail = 0;
            xSemaphoreGive(mutex);
        }
    }
};

// ==========================================================================
// 全局变量
// ==========================================================================
ICM20948_WE imu_thigh(ADDR_THIGH);
ICM20948_WE imu_shank(ADDR_SHANK);

BLEServer *pServer = NULL;
BLECharacteristic *pTx = NULL;
BLECharacteristic *pRx = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

volatile bool isRunning = false;
volatile uint8_t sensorCount = 1;  // 1=SHANK, 2=DUAL
String sessionId = "";
uint64_t sessionStartUs = 0;

RingBuffer dataBuffer;

TaskHandle_t samplingTaskHandle = NULL;
TaskHandle_t transmitTaskHandle = NULL;

volatile uint32_t sampleCount = 0;
volatile uint32_t transmitCount = 0;

// ========== NEW: Flush机制 ==========
SemaphoreHandle_t flushSemaphore = NULL;  // 信号量：触发flush
// ====================================

// ==========================================================================
// BLE回调
// ==========================================================================
class ServerCB : public BLEServerCallbacks {
    void onConnect(BLEServer *s) {
        deviceConnected = true;
        Serial.println(F("BLE Connected"));
    }
    void onDisconnect(BLEServer *s) {
        deviceConnected = false;
        Serial.println(F("BLE Disconnected"));
    }
};

class RxCB : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *c) {
        String v = c->getValue();
        if (v.length() == 0) return;
        
        Serial.print(F("CMD: ")); Serial.println(v);
        
        if (v == "START") {
            if (!isRunning) {
                // 生成session ID
                sessionId = String(millis());
                sessionStartUs = esp_timer_get_time();
                dataBuffer.clear();
                sampleCount = 0;
                transmitCount = 0;
                isRunning = true;
                Serial.println(F("Recording started"));
            }
        }
        else if (v == "STOP") {
            if (isRunning) {
                isRunning = false;
                Serial.println(F("Recording stopped"));
                
                // ========== NEW: 等待采样完全停止，然后触发flush ==========
                vTaskDelay(pdMS_TO_TICKS(100));  // 等待100ms让采样任务完全停止
                
                int remaining = dataBuffer.count();
                Serial.print(F("Buffer has "));
                Serial.print(remaining);
                Serial.println(F(" samples remaining"));
                
                if (remaining > 0) {
                    // 触发flush
                    xSemaphoreGive(flushSemaphore);
                    Serial.println(F("Flush triggered"));
                } else {
                    Serial.println(F("No data to flush"));
                }
                // ==========================================================
            }
        }
        else if (v == "MODE SHANK") {
            if (!isRunning) {
                sensorCount = 1;
                Serial.println(F("Mode: SHANK"));
            }
        }
        else if (v == "MODE DUAL") {
            if (!isRunning) {
                sensorCount = 2;
                Serial.println(F("Mode: DUAL"));
            }
        }
    }
};

// ==========================================================================
// 读取IMU数据
// ==========================================================================
void readIMU(ICM20948_WE &imu, Sample &sample, uint8_t sensor_id, uint64_t timestamp) {
    imu.readSensor();
    
    xyzFloat acc;
    xyzFloat gyro;
    imu.getGValues(&acc);
    imu.getGyrValues(&gyro);
    
    sample.t_us = timestamp;
    sample.ax = acc.x;
    sample.ay = acc.y;
    sample.az = acc.z;
    sample.gx = gyro.x;
    sample.gy = gyro.y;
    sample.gz = gyro.z;
    sample.sensor_id = sensor_id;
}

// ==========================================================================
// FreeRTOS任务：采样任务
// ==========================================================================
void samplingTask(void *param) {
    TickType_t lastWakeTime = xTaskGetTickCount();
    const TickType_t period = pdMS_TO_TICKS(SAMPLE_INTERVAL_MS);
    
    Serial.println(F("Sampling task started"));
    
    while (1) {
        if (isRunning) {
            uint64_t currentUs = esp_timer_get_time();
            uint64_t relativeUs = currentUs - sessionStartUs;
            
            Sample sample;
            
            // 读取小腿IMU（总是读）
            readIMU(imu_shank, sample, 2, relativeUs);
            dataBuffer.push(sample);
            sampleCount++;
            
            // 读取大腿IMU（如果是双传感器模式）
            if (sensorCount == 2) {
                readIMU(imu_thigh, sample, 1, relativeUs);
                dataBuffer.push(sample);
                sampleCount++;
            }
            
            // 统计输出（每100个样本）
            if (sampleCount % 100 == 0) {
                Serial.print(F("Samples: "));
                Serial.print(sampleCount);
                Serial.print(F(", Transmitted: "));
                Serial.print(transmitCount);
                Serial.print(F(", Buffer: "));
                Serial.println(dataBuffer.count());
            }
        }
        
        vTaskDelayUntil(&lastWakeTime, period);
    }
}

// ==========================================================================
// FreeRTOS任务：BLE传输任务
// ==========================================================================
void transmitTask(void *param) {
    Sample batch[BATCH_SIZE];
    
    Serial.println(F("BLE transmit task started"));
    
    while (1) {
        // 检查BLE连接
        if (!deviceConnected) {
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }
        
        int bufferCount = dataBuffer.count();
        
        // ========== NEW: 检查是否需要flush ==========
        if (xSemaphoreTake(flushSemaphore, 0) == pdTRUE) {
            // 收到flush信号，发送所有剩余数据
            Serial.println(F("Flushing remaining data..."));
            
            bufferCount = dataBuffer.count();
            if (bufferCount > 0) {
                // 分批发送剩余数据
                while (bufferCount > 0) {
                    int toSend = (bufferCount >= BATCH_SIZE) ? BATCH_SIZE : bufferCount;
                    
                    int collected = 0;
                    for (int i = 0; i < toSend; i++) {
                        if (dataBuffer.pop(&batch[i])) {
                            collected++;
                        } else {
                            break;
                        }
                    }
                    
                    if (collected > 0) {
                        transmitBatch(batch, collected);
                        Serial.print(F("Flushed "));
                        Serial.print(collected);
                        Serial.print(F(" samples, "));
                        Serial.print(dataBuffer.count());
                        Serial.println(F(" remaining"));
                    }
                    
                    bufferCount = dataBuffer.count();
                    vTaskDelay(pdMS_TO_TICKS(50));  // 给BLE一点时间
                }
                
                Serial.println(F("✓ Flush complete, all data sent"));
            } else {
                Serial.println(F("✓ No data to flush"));
            }
            
            continue;  // 跳过正常传输检查
        }
        // ============================================
        
        // 正常传输：如果缓冲区有足够数据就发送
        if (bufferCount >= BATCH_SIZE) {
            // 从缓冲区读取数据
            int collected = 0;
            for (int i = 0; i < BATCH_SIZE; i++) {
                if (dataBuffer.pop(&batch[i])) {
                    collected++;
                } else {
                    break;
                }
            }
            
            // 通过BLE发送
            if (collected > 0) {
                transmitBatch(batch, collected);
            }
        }
        
        vTaskDelay(pdMS_TO_TICKS(100));  // 每100ms检查一次
    }
}

// ==========================================================================
// 通过BLE发送批量数据 (CSV格式)
// ==========================================================================
void transmitBatch(Sample* batch, int count) {
    if (!deviceConnected || pTx == NULL) {
        return;
    }
    
    // 创建CSV字符串
    String csv = "session_id,device_id,sensor_id,t_us,ax,ay,az,gx,gy,gz\n";
    
    for (int i = 0; i < count; i++) {
        // session_id
        csv += sessionId;
        csv += ",";
        
        // device_id
        csv += deviceId;
        csv += ",";
        
        // sensor_id
        csv += (batch[i].sensor_id == 1) ? "thigh" : "shank";
        csv += ",";
        
        // t_us
        csv += String((unsigned long long)batch[i].t_us);
        csv += ",";
        
        // ax, ay, az, gx, gy, gz
        csv += String(batch[i].ax, 6);
        csv += ",";
        csv += String(batch[i].ay, 6);
        csv += ",";
        csv += String(batch[i].az, 6);
        csv += ",";
        csv += String(batch[i].gx, 6);
        csv += ",";
        csv += String(batch[i].gy, 6);
        csv += ",";
        csv += String(batch[i].gz, 6);
        csv += "\n";
    }
    
    // 通过BLE Notify发送CSV数据
    // BLE一次最多发送512字节，需要分包
    int csvLen = csv.length();
    int offset = 0;
    const int chunkSize = 500;  // 每次发送500字节
    
    while (offset < csvLen) {
        int len = min(chunkSize, csvLen - offset);
        String chunk = csv.substring(offset, offset + len);
        
        pTx->setValue(chunk.c_str());
        pTx->notify();
        
        offset += len;
        delay(20);  // 给BLE一点时间发送
    }
    
    transmitCount += count;
    Serial.print(F("BLE sent: "));
    Serial.print(count);
    Serial.println(F(" samples"));
}

// ==========================================================================
// Setup
// ==========================================================================
void setup() {
    Serial.begin(115200);
    delay(1000);
    
    Serial.println(F("\n=== KneeGuard v7.1 ==="));
    Serial.println(F("FreeRTOS + BLE Transmit + Flush"));
    Serial.println();
    
    // ========== NEW: 创建flush信号量 ==========
    flushSemaphore = xSemaphoreCreateBinary();
    if (flushSemaphore == NULL) {
        Serial.println(F("Failed to create flush semaphore!"));
        while(1) delay(1000);
    }
    Serial.println(F("Flush semaphore created"));
    // ==========================================
    
    // I2C初始化（保持原来的方式）
    Wire.begin(8, 9);
    delay(100);
    
    // IMU初始化（保持原来的顺序和方式）
    Serial.println(F("Init Shank IMU..."));
    if (!imu_shank.init()) {
        Serial.println(F("SHANK FAIL!"));
        while(1) delay(1000);
    }
    imu_shank.autoOffsets();
    imu_shank.setAccRange(ICM20948_ACC_RANGE_8G);
    imu_shank.setGyrRange(ICM20948_GYRO_RANGE_1000);
    imu_shank.setAccDLPF(ICM20948_DLPF_6);
    imu_shank.setGyrDLPF(ICM20948_DLPF_6);
    Serial.println(F("SHANK OK"));
    
    Serial.println(F("Init Thigh IMU..."));
    if (!imu_thigh.init()) {
        Serial.println(F("THIGH SKIP"));
        sensorCount = 1;
    } else {
        imu_thigh.autoOffsets();
        imu_thigh.setAccRange(ICM20948_ACC_RANGE_8G);
        imu_thigh.setGyrRange(ICM20948_GYRO_RANGE_1000);
        imu_thigh.setAccDLPF(ICM20948_DLPF_6);
        imu_thigh.setGyrDLPF(ICM20948_DLPF_6);
        Serial.println(F("THIGH OK"));
        sensorCount = 2;
    }
    
    // BLE初始化
    Serial.println(F("\nInit BLE..."));
    BLEDevice::init(DEVICE_NAME);
    BLEDevice::setMTU(512);
    
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new ServerCB());
    
    BLEService *pSvc = pServer->createService(SERVICE_UUID);
    
    pTx = pSvc->createCharacteristic(TX_UUID, BLECharacteristic::PROPERTY_NOTIFY);
    pTx->addDescriptor(new BLE2902());
    
    pRx = pSvc->createCharacteristic(RX_UUID, BLECharacteristic::PROPERTY_WRITE);
    pRx->setCallbacks(new RxCB());
    
    pSvc->start();
    
    BLEAdvertising *pAdv = pServer->getAdvertising();
    pAdv->addServiceUUID(SERVICE_UUID);
    pAdv->setScanResponse(true);
    pAdv->start();
    
    Serial.println(F("BLE Started"));
    
    // 创建FreeRTOS任务
    xTaskCreate(
        samplingTask,
        "Sampling",
        4096,
        NULL,
        3,  // 高优先级
        &samplingTaskHandle
    );
    
    xTaskCreate(
        transmitTask,
        "Transmit",
        12288,
        NULL,
        2,  // 低优先级
        &transmitTaskHandle
    );
    
    Serial.println(F("\n=== READY ==="));
    Serial.println(F("Send 'START' to begin recording"));
    Serial.println();
}

// ==========================================================================
// Loop
// ==========================================================================
void loop() {
    // 处理BLE重连
    if (!deviceConnected && oldDeviceConnected) {
        delay(500);
        pServer->startAdvertising();
        oldDeviceConnected = deviceConnected;
        Serial.println(F("Restart BLE advertising"));
    }
    
    if (deviceConnected && !oldDeviceConnected) {
        oldDeviceConnected = deviceConnected;
    }
    
    delay(1000);
}
