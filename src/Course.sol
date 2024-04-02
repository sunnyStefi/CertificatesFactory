//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.18;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @notice This contract govern the creation, transfer and management of certificates.
 */
contract Course is ERC1155, AccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32 public constant EVALUATOR = keccak256("EVALUATOR");
    bytes32 public constant STUDENT = keccak256("STUDENT"); //todo assign

    event Courses_CourseCreated(uint256 indexed courseId);
    event Courses_CoursesRemoved(uint256 indexed courseId);
    event Courses_EvaluationCompleted(uint256 indexed courseId, address indexed student, uint256 indexed mark);
    event Courses_Withdrawal(address sender, uint256 amount);

    error Course_IllegalMark(uint256 mark);
    error Courses_NoCourseIsRegisteredForTheUser(address user);
    error Courses_CourseNotRegisteredForTheUser(uint256 courseId, address student);
    error Courses_WithdrawalFailed();
    error Course_AddressNotValid();
    error Course_BuyCourse_NotEnoughEthToBuyCourse(uint256 fee, uint256 value);
    error Course_EvaluatorAlreadyAssignedForThisCourse(address evaluator);
    error Course_TooManyEvaluatorsForThisCourse(uint256 maxEvaluatorsAmount);
    error Course_SetMaxAmountCannotBeZero(uint256 newAmount);
    error Course_EvaluatorNotAssignedToCourse(uint256 course, address evaluator);
    error Course_CourseIdDoesNotExist(uint256 courseId);
    error Course_EvaluatorNotAssignedForThisCourse(address evaluator);
    error Course_StudentCannotBeEvaluator(address student);
    error Course_DoesNotHaveExactlyOnePlaceNFT(address student, uint256 balance);
    error Course_StudentNotEnrolled(address student);
    error Course_StudentAlreadyEvaluated(address student);
    error Courses_NotEnoughFunds(uint256 amount, uint256 balance);
    error Course_TooManyPlacesForThisCourse(uint256 actualPlaces, uint256 desiredPlaces);
    error Course_CourseIdExceedsMaxUint256Value();
    error Course_MaxPlacesPerCourseReached();
    error Course_StudentCannotBuyMoreThanOnePlace();

    uint256 public constant BASE_COURSE_FEE = 0.01 ether;
    uint256 public constant MAX_UINT = type(uint256).max;
    string public constant JSON = ".json";
    string public constant ID_JSON = "/{id}.json";
    string public constant PROTOCOL = "https://ipfs.io/ipfs/";
    string public constant URI_PINATA = "QmZeczzyz6ow8vNJrP7jBnZPdF7CQYrcUjqQZrgXC6hXMF";

    uint256 private s_coursesTypeCounter;
    uint256 private MAX_EVALUATORS = 5;
    uint256 private MAX_PLACES_PER_COURSE = 100;

    mapping(uint256 => CourseStruct) private s_courses;
    mapping(address => uint256[]) private s_userToCourses;
    mapping(uint256 => EvaluatedStudent[]) private s_courseToEvaluatedStudents;

    struct CourseStruct {
        uint256 placeFee;
        uint256 placeNumber;
        uint256 placesPurchased;
        uint256 passedStudents;
        address creator;
        string uri;
        EnumerableSet.AddressSet evaluators;
        EnumerableSet.AddressSet enrolledStudents;
    }

    struct EvaluatedStudent {
        uint256 mark;
        uint256 date;
        address student;
        address evaluator;
    }

    modifier validateMark(uint256 mark) {
        if (mark < 1 || mark > 10) {
            revert Course_IllegalMark(mark);
        }
        _;
    }

    modifier validateAddress(address user) {
        if (user == address(0)) {
            revert Course_AddressNotValid();
        }
        _;
    }

    modifier validateAmount(uint256 amount) {
        if (amount >= MAX_UINT) {
            revert Course_CourseIdExceedsMaxUint256Value();
        }
        _;
    }

    constructor() ERC1155(string.concat(PROTOCOL, URI_PINATA, ID_JSON)) {
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(EVALUATOR, ADMIN);

        _grantRole(ADMIN, _msgSender());
        _grantRole(ADMIN, address(this));

        s_coursesTypeCounter = 0;
    }

    /**
     * 1 Courses
     */
    function createCourse(uint256 id, uint256 value, bytes memory data, string memory uri, uint256 fee)
        public
        onlyRole(ADMIN)
        validateAmount(id)
        validateAmount(value)
        returns (uint256)
    {
        setCoursePlacesData(id, value, uri, fee);
        _mint(_msgSender(), id, value, data);
        setApprovalForAll(_msgSender(), true);
        emit Courses_CourseCreated(s_coursesTypeCounter);
        return id;
    }

    function removePlaces(address from, uint256 id, uint256 value)
        public
        onlyRole(ADMIN)
        validateAmount(id)
        validateAmount(value)
    {
        removePlaceData(id, value);
        _burn(from, id, value);
        emit Courses_CoursesRemoved(value);
    }

    /**
     * 2 Evaluator
     */
    function setUpEvaluator(address evaluator, uint256 courseId)
        public
        onlyRole(ADMIN)
        validateAddress(evaluator)
        validateAmount(courseId)
    {
        if (s_courses[courseId].evaluators.contains(evaluator)) {
            revert Course_EvaluatorAlreadyAssignedForThisCourse(evaluator);
        }
        //EnumerableSet uses 0 as a sentinel value -> - 1 to the desired length
        if (s_courses[courseId].evaluators.length() > (MAX_EVALUATORS - 1)) {
            revert Course_TooManyEvaluatorsForThisCourse(MAX_EVALUATORS);
        }
        s_courses[courseId].evaluators.add(evaluator);
        grantRole(EVALUATOR, evaluator);
    }

    function removeEvaluator(address evaluator, uint256 courseId) public onlyRole(ADMIN) validateAmount(courseId) {
        if (!s_courses[courseId].evaluators.contains(evaluator)) {
            revert Course_EvaluatorNotAssignedForThisCourse(evaluator);
        }
        s_courses[courseId].evaluators.remove(evaluator);
        revokeRole(EVALUATOR, evaluator);
    }

    /**
     * 3 Purchase
     */
    function buyPlace(uint256 courseId) public payable validateAmount(courseId) {
        //todo cant buy a course twice replicated courses
        if (msg.value < s_courses[courseId].placeFee) {
            revert Course_BuyCourse_NotEnoughEthToBuyCourse(s_courses[courseId].placeFee, msg.value);
        }
        if (s_courses[courseId].evaluators.length() == 0) {
            revert Course_EvaluatorNotAssignedForThisCourse(address(0));
        }
        if (s_courses[courseId].enrolledStudents.contains(_msgSender())) {
            revert Course_StudentCannotBuyMoreThanOnePlace();
        }
        s_userToCourses[_msgSender()].push(courseId);
        s_courses[courseId].placesPurchased += 1;
        s_courses[courseId].enrolledStudents.add(_msgSender());
    }

    //todo return values
    function transferPlaceNFT(address student, uint256 courseId)
        public
        onlyRole(ADMIN)
        validateAmount(courseId)
        validateAddress(student)
    {
        if (!s_courses[courseId].enrolledStudents.contains(student)) {
            revert Courses_CourseNotRegisteredForTheUser(courseId, student);
        }

        safeTransferFrom(s_courses[courseId].creator, student, courseId, 1, "0x");
    }

    /**
     *  4 Evaluation
     */
    function evaluate(uint256 courseId, address student, uint256 mark)
        public
        onlyRole(EVALUATOR)
        validateAmount(courseId)
        validateAddress(student)
        validateMark(mark)
    {
        if (!s_courses[courseId].evaluators.contains(_msgSender())) {
            revert Course_EvaluatorNotAssignedToCourse(courseId, _msgSender());
        }
        if (s_courses[courseId].evaluators.contains(student)) {
            revert Course_StudentCannotBeEvaluator(student);
        }
        if (!s_courses[courseId].enrolledStudents.contains(student)) {
            revert Course_StudentNotEnrolled(student);
        }
        if (isStudentEvaluated(courseId, student)) {
            revert Course_StudentAlreadyEvaluated(student);
        }
        if (this.balanceOf(student, courseId) != 1) {
            revert Course_DoesNotHaveExactlyOnePlaceNFT(student, this.balanceOf(student, courseId));
        }
        if (s_userToCourses[student].length == 0) {
            revert Courses_NoCourseIsRegisteredForTheUser(student);
        }
        if (mark >= 6) {
            s_courses[courseId].passedStudents += 1;
        }
        s_courseToEvaluatedStudents[courseId].push(EvaluatedStudent(mark, block.timestamp, student, _msgSender()));
        emit Courses_EvaluationCompleted(courseId, student, mark);
    }

    /**
     * 5 Make certificates
     */
    function makeCertificates(uint256 courseId, string memory certificateUri)
        public
        onlyRole(ADMIN)
        validateAmount(courseId)
    {
        uint256 evaluatedStudents = s_courseToEvaluatedStudents[courseId].length;
        uint256 notSoldPlaces = s_courses[courseId].placeNumber - s_courses[courseId].placesPurchased;

        removePlaces(_msgSender(), courseId, notSoldPlaces);

        for (uint256 i = 0; i < evaluatedStudents; i++) {
            if (s_courseToEvaluatedStudents[courseId][i].mark < 6) {
                removePlaces(s_courseToEvaluatedStudents[courseId][i].student, courseId, 1);
            } else {
                setCourseUri(courseId, certificateUri);
            }
        }
    }

    /**
     * 6 Funds management
     */
    function withdraw(uint256 amount) public payable onlyRole(ADMIN) {
        if (amount > address(this).balance) {
            revert Courses_NotEnoughFunds(amount, address(this).balance);
        }
        (bool succ,) = payable(_msgSender()).call{value: amount}("");

        if (!succ) {
            revert Courses_WithdrawalFailed();
        }
        emit Courses_Withdrawal(_msgSender(), amount);
    }

    /**
     * Storage Utils
     */
    function setCoursePlacesData(uint256 courseId, uint256 value, string memory uri, uint256 fee)
        private
        onlyRole(ADMIN)
    {
        if (s_courses[courseId].placeNumber + value >= MAX_PLACES_PER_COURSE) {
            revert Course_MaxPlacesPerCourseReached();
        }
        s_courses[courseId].placeFee = fee;
        s_courses[courseId].placeNumber += value;
        s_courses[courseId].creator = _msgSender();
        s_courses[courseId].uri = uri;
    }

    function removePlaceData(uint256 courseId, uint256 value) public onlyRole(ADMIN) {
        if (s_courses[courseId].placeNumber < value) {
            revert Course_TooManyPlacesForThisCourse(s_courses[courseId].placeNumber, value);
        }
        if (s_courses[courseId].creator == address(0)) {
            revert Course_CourseIdDoesNotExist(courseId);
        }
        s_courses[courseId].placeNumber -= value;
    }

    function contractURI() public pure returns (string memory) {
        return string.concat(PROTOCOL, URI_PINATA, "/collection.json");
    }

    function isStudentEvaluated(uint256 courseId, address student) public view returns (bool) {
        for (uint256 i = 0; i < s_courseToEvaluatedStudents[courseId].length; i++) {
            if (s_courseToEvaluatedStudents[courseId][i].student == student) {
                return true;
            }
        }
        return false;
    }

    /**
     * Getters
     */
    function getEvaluators(uint256 courseId)
        public
        view
        validateAmount(courseId)
        returns (address[] memory evaluators)
    {
        return s_courses[courseId].evaluators.values();
    }

    function getCourseToEnrolledStudents(uint256 courseId) public view returns (address[] memory) {
        return s_courses[courseId].enrolledStudents.values();
    }

    function getCoursesPerUser(address user) public view returns (uint256[] memory) {
        return s_userToCourses[user];
    }

    function getCourseToEvaluateStudents(uint256 courseId) public view returns (EvaluatedStudent[] memory) {
        return s_courseToEvaluatedStudents[courseId];
    }

    function getPromotedStudents(uint256 courseId)
        public
        view
        returns (address[] memory, address[] memory, uint256, uint256)
    {
        uint256 countPromoted = 0;
        uint256 countFailed = 0;
        uint256 evaluatedStudentsPerCourse = s_courseToEvaluatedStudents[courseId].length;
        address[] memory promoted = new address[](evaluatedStudentsPerCourse);
        address[] memory failed = new address[](evaluatedStudentsPerCourse);
        for (uint256 i = 0; i < evaluatedStudentsPerCourse; i++) {
            if (s_courseToEvaluatedStudents[courseId][i].mark >= 6) {
                promoted[countPromoted] = s_courseToEvaluatedStudents[courseId][i].student;
                countPromoted++;
            }
            if (s_courseToEvaluatedStudents[courseId][i].mark < 6) {
                failed[countFailed] = s_courseToEvaluatedStudents[courseId][i].student;
                countFailed++;
            }
        }

        assembly {
            mstore(promoted, countPromoted)
            mstore(failed, countFailed)
        }

        return (promoted, failed, countPromoted, countFailed);
    }

    function getCoursesCounter() public view returns (uint256) {
        return s_coursesTypeCounter;
    }

    function getCreatedPlacesCounter(uint256 courseId) public view returns (uint256) {
        return s_courses[courseId].placeNumber;
    }

    function getPurchasedPlacesCounter(uint256 courseId) public view returns (uint256) {
        return s_courses[courseId].placesPurchased;
    }

    function getEvaluatedStudents(uint256 courseId) public view returns (uint256) {
        return s_courseToEvaluatedStudents[courseId].length;
    }

    function getMaxEvaluatorsPerCourse() public view returns (uint256) {
        return MAX_EVALUATORS;
    }

    function getMaxPlacesPerCourse() public view returns (uint256) {
        return MAX_PLACES_PER_COURSE;
    }

    function getEvaluatorsPerCourse(uint256 courseId) public view returns (uint256) {
        return s_courses[courseId].evaluators.length();
    }

    function getCourseCreator(uint256 courseId) public view returns (address) {
        return s_courses[courseId].creator;
    }

    function getCourseUri(uint256 courseId) public view returns (string memory) {
        return s_courses[courseId].uri;
    }

    function getPassedStudents(uint256 courseId) public view returns (uint256) {
        return s_courses[courseId].passedStudents;
    }

    /**
     * Setters
     */
    function setUri(string memory uri) public onlyRole(ADMIN) {
        _setURI(uri);
    }

    function _setURI(string memory newuri) internal override {
        super._setURI(newuri);
    }

    function setMaxEvaluatorsAmount(uint256 newAmount) public {
        if (newAmount == 0) {
            revert Course_SetMaxAmountCannotBeZero(newAmount);
        }
        MAX_EVALUATORS = newAmount;
    }

    function setMaxPlacesAmount(uint256 newAmount) public {
        if (newAmount == 0) {
            revert Course_SetMaxAmountCannotBeZero(newAmount);
        }
        MAX_PLACES_PER_COURSE = newAmount;
    }

    function setCourseUri(uint256 courseId, string memory uri) public onlyRole(ADMIN) {
        s_courses[courseId].uri = uri;
    }

    /**
     * Overrides
     */
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory data)
        public
        override
        onlyRole(ADMIN)
    {
        super.safeTransferFrom(from, to, id, value, data);
    }

    function uri(uint256 _tokenid) public view override returns (string memory) {
        return s_courses[_tokenid].uri;
    }

    function setApprovalForAll(address operator, bool approved) public override onlyRole(ADMIN) {
        super.setApprovalForAll(operator, approved);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
